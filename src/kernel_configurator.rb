# frozen_string_literal: true

require "fileutils"
require_relative "utils"
require_relative "patch_fetcher"

# Tworzy .config dla jądra:
#   1. Pobiera bazową konfigurację Fedory lub kopiuje własną
#   2. Pobiera i stosuje wbudowane patche (BORE, Valve VRAM)
#   3. Stosuje patche użytkownika z patches/
#   4. Nakłada tweaki NVIDIA-friendly
#   5. Nakłada optymalizacje gamingowe (BORE, NTSYNC, sched_ext, BBR v3)
#   6. Ustawia poziom CPU (v1/v2/v3/v4) i flagi kompilatora
#   7. Ustawia localversion
#   8. make olddefconfig
class KernelConfigurator
  class Error < StandardError; end

  def initialize(cfg, log)
    @cfg = cfg
    @log = log
    @src = cfg.source_dir
  end

  def configure
    raise Error, "Katalog źródeł nie istnieje: #{@src}" unless Dir.exist?(@src)

    @log.info "CPU target: #{@cfg.cpu_level_label}"

    apply_base_config
    apply_auto_patches     # BORE, Valve VRAM (pobrane z GitHub)
    apply_user_patches     # patches/*.patch użytkownika
    apply_nvidia_tweaks    if @cfg.nvidia_enabled?
    apply_gaming_tweaks
    apply_cpu_level
    apply_compiler_tweaks
    set_localversion
    finalize_config
  end

  private

  # ===========================================================================
  # 1. BAZA KONFIGURACJI
  # ===========================================================================
  def apply_base_config
    if @cfg.base_config == "fedora"
      fetch_fedora_config
    else
      custom = File.expand_path(@cfg.base_config)
      raise Error, "Plik .config nie istnieje: #{custom}" unless File.exist?(custom)

      @log.info "Kopiowanie własnego .config z #{custom}"
      FileUtils.cp(custom, dot_config)
    end
  end

  def fetch_fedora_config
    running_config = "/boot/config-#{`uname -r`.strip}"
    if File.exist?(running_config)
      @log.info "Kopiowanie .config z działającego jądra Fedory: #{running_config}"
      FileUtils.cp(running_config, dot_config)
    else
      @log.warn "Nie znaleziono /boot/config-$(uname -r) — pobieranie z Fedora SCM..."
      fedora_config_url = "https://src.fedoraproject.org/rpms/kernel/raw/main/f/kernel-#{@cfg.arch}.config"
      Utils.run!("curl -L -s -o #{dot_config.shellescape} #{fedora_config_url.shellescape}", @log)
      raise Error, "Pobieranie .config Fedory nie powiodło się" unless File.exist?(dot_config) && File.size(dot_config) > 1024
    end
    @log.info "Baza .config Fedory gotowa."
  end

  # ===========================================================================
  # 2. AUTO-PATCHE (BORE, Valve VRAM)
  # ===========================================================================
  def apply_auto_patches
    fetcher = PatchFetcher.new(@cfg, @log)
    patches = fetcher.fetch_all

    if patches.empty?
      @log.info "Brak auto-patchy do zastosowania (zostaną użyte opcje CONFIG)."
      return
    end

    @log.info "Stosowanie #{patches.size} auto-patch(y) (BORE/Valve)..."
    apply_patch_list(patches)
  end

  # ===========================================================================
  # 3. PATCHE UŻYTKOWNIKA
  #
  # Obsługuje dwa typy plików (rekurencyjnie przez podkatalogi):
  #
  #   *.patch  — prawdziwy diff na kodzie źródłowym kernela (patch -p1)
  #              Użyj dla: BORE scheduler z GitHub, własnych poprawek kodu
  #              Ryzyko: mogą nie pasować gdy zmienisz wersję kernela
  #
  #   *.config — fragment konfiguracji kconfig nakładany na .config
  #              Użyj dla: własnych opcji CONFIG_*, zawsze działa
  #              Format: standardowy kconfig, linia po linii:
  #                CONFIG_FOO=y
  #                # CONFIG_BAR is not set
  #                CONFIG_BAZ=1234
  #
  # Kolejność stosowania: alfabetyczna, podkatalogi po plikach z roota.
  # Podkatalogi gaming/ i nvidia/ są skanowane automatycznie.
  # ===========================================================================
  def apply_user_patches
    patches_dir = File.expand_path(@cfg.patches_dir)
    unless Dir.exist?(patches_dir)
      @log.info "Brak katalogu patches/, pomijam patche użytkownika."
      return
    end

    # Zbierz pliki rekurencyjnie: najpierw root, potem podkatalogi — wszystko posortowane
    source_patches = Dir[File.join(patches_dir, "*.patch")].sort
    config_frags   = Dir[File.join(patches_dir, "*.config")].sort
    sub_patches    = Dir[File.join(patches_dir, "**", "*.patch")].reject { |f| File.dirname(f) == patches_dir }.sort
    sub_configs    = Dir[File.join(patches_dir, "**", "*.config")].reject { |f| File.dirname(f) == patches_dir }.sort

    all_source  = source_patches + sub_patches
    all_configs = config_frags   + sub_configs

    if all_source.empty? && all_configs.empty?
      @log.info "Brak patchy użytkownika w #{patches_dir} (ani *.patch ani *.config)."
      return
    end

    unless all_source.empty?
      @log.info "Stosowanie #{all_source.size} patch(y) źródłowych (patch -p1)..."
      apply_source_patch_list(all_source)
    end

    unless all_configs.empty?
      @log.info "Stosowanie #{all_configs.size} fragmentu/ów konfiguracji (*.config)..."
      apply_config_fragment_list(all_configs)
    end
  end

  # Stosuje prawdziwe diffy na kodzie źródłowym kernela
  def apply_source_patch_list(patches)
    patches.each do |patch|
      rel = patch.sub(File.expand_path(@cfg.patches_dir) + "/", "")
      @log.info "  [patch]  #{rel}"
      Utils.run!(
        "patch -d #{@src.shellescape} -p1 --forward --no-backup-if-mismatch < #{patch.shellescape}",
        @log
      )
    end
  end

  # Nakłada fragment kconfig na .config — działa jak merge, linia po linii
  # Obsługuje:
  #   CONFIG_FOO=y          → włącza
  #   # CONFIG_FOO is not set → wyłącza
  #   CONFIG_FOO=1234       → ustawia wartość
  def apply_config_fragment_list(frags)
    frags.each do |frag|
      rel = frag.sub(File.expand_path(@cfg.patches_dir) + "/", "")
      @log.info "  [config] #{rel}"
      File.readlines(frag, chomp: true).each do |line|
        line = line.strip
        next if line.empty?

        if (m = line.match(/^(CONFIG_\w+)=(.+)$/))
          # CONFIG_FOO=y / CONFIG_FOO=m / CONFIG_FOO="string" / CONFIG_FOO=1234
          val = case m[2]
                when "y" then :enable
                when "m" then :module
                when "n" then :disable
                else m[2]
                end
          set_config_option(m[1], val)

        elsif (m = line.match(/^#\s*(CONFIG_\w+)\s+is not set$/))
          # # CONFIG_FOO is not set
          set_config_option(m[1], :disable)

        elsif line.start_with?("#")
          # Zwykły komentarz — pomijamy
          next

        else
          @log.warn "  [config] Nieznana linia, pomijam: #{line}"
        end
      end
    end
  end

  # ===========================================================================
  # 4. TWEAKI NVIDIA / akmod
  # ===========================================================================
  NVIDIA_OPTIONS = {
    # Podpisywanie modułów — akmod nie korzysta z podpisanych modułów
    "CONFIG_MODULE_SIG"              => :disable,
    "CONFIG_MODULE_SIG_ALL"          => :disable,
    "CONFIG_MODULE_SIG_FORCE"        => :disable,

    # Symbole wymagane przez sterownik NVIDIA
    "CONFIG_KALLSYMS_ALL"            => :enable,

    # DMA-BUF Heaps — wymagane przez NVIDIA GSP firmware (RTX 2000+)
    "CONFIG_DMABUF_HEAPS"            => :enable,
    "CONFIG_DMABUF_HEAPS_SYSTEM"     => :enable,
    "CONFIG_DMABUF_HEAPS_CMA"        => :enable,

    # Unified Memory (nvidia-uvm)
    "CONFIG_IOMMU_API"               => :enable,
    "CONFIG_IOMMU_SUPPORT"           => :enable,

    # Tryb graficzny — wymagany przez nvidia-drm
    "CONFIG_DRM"                     => :enable,
    "CONFIG_DRM_KMS_HELPER"          => :enable,
    "CONFIG_DRM_FBDEV_EMULATION"     => :enable,

    # Wyłącz Nouveau — konflikt z NVIDIA proprietary
    "CONFIG_DRM_NOUVEAU"             => :disable,

    # PCIe / ACPI — wymagane dla GPUs
    "CONFIG_HOTPLUG_PCI"             => :enable,
    "CONFIG_HOTPLUG_PCI_PCIE"        => :enable,
    "CONFIG_ACPI"                    => :enable,
    "CONFIG_PCI_MSI"                 => :enable,

    # Resizable BAR (ReBAR) — wymagane dla pełnej wydajności NVIDIA na PCIe 4.0+
    "CONFIG_PCI_REALLOC_ENABLE_AUTO" => :enable
  }.freeze

  def apply_nvidia_tweaks
    @log.info "Stosowanie tweaków konfiguracji NVIDIA/akmod..."
    tweaks = NVIDIA_OPTIONS.dup
    tweaks["CONFIG_MODULE_SIG"]   = :disable if @cfg.disable_module_signing?
    tweaks["CONFIG_KALLSYMS_ALL"] = :enable  if @cfg.kallsyms_all?
    tweaks["CONFIG_DMABUF_HEAPS"] = :enable  if @cfg.dmabuf_heaps?
    apply_config_options(tweaks)
  end

  # ===========================================================================
  # 5. OPTYMALIZACJE GAMINGOWE
  # ===========================================================================

  # Bazowe optymalizacje wydajnościowe (zawsze włączone)
  BASE_GAMING_OPTIONS = {
    # --- Preemption: tryb desktop/gaming ---
    "CONFIG_PREEMPT"                        => :enable,
    "CONFIG_PREEMPT_VOLUNTARY"              => :disable,
    "CONFIG_PREEMPT_NONE"                   => :disable,

    # --- Timer: 1000 Hz dla niskiej latencji ---
    "CONFIG_HZ_1000"                        => :enable,
    "CONFIG_HZ"                             => "1000",
    "CONFIG_HZ_300"                         => :disable,
    "CONFIG_HZ_250"                         => :disable,
    "CONFIG_HZ_100"                         => :disable,

    # --- Hugepages: wydajność GPU i gier ---
    "CONFIG_TRANSPARENT_HUGEPAGE"           => :enable,
    "CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS"    => :enable,
    "CONFIG_TRANSPARENT_HUGEPAGE_MADVISE"   => :disable,

    # --- Multi-Gen LRU: nowoczesny page reclaim ---
    "CONFIG_LRU_GEN"                        => :enable,
    "CONFIG_LRU_GEN_ENABLED"                => :enable,
    "CONFIG_LRU_GEN_STATS"                  => :disable,

    # --- ZRAM: kompresja RAM (lepiej niż swap na dysku) ---
    "CONFIG_ZRAM"                           => :enable,
    "CONFIG_ZRAM_DEF_COMP_ZSTD"            => :enable,

    # --- ZSWAP: dodatkowe buforowanie swap ---
    "CONFIG_ZSWAP"                          => :enable,

    # --- DAMON: monitorowanie dostępu do pamięci (auto hugepages) ---
    "CONFIG_DAMON"                          => :enable,
    "CONFIG_DAMON_VADDR"                    => :enable,
    "CONFIG_DAMON_PADDR"                    => :enable,

    # --- Wyłącz debugging (spowalnia kernel) ---
    "CONFIG_DEBUG_KERNEL"                   => :disable,
    "CONFIG_DEBUG_INFO"                     => :disable,
    "CONFIG_DEBUG_INFO_DWARF4"              => :disable,
    "CONFIG_DEBUG_INFO_DWARF5"              => :disable,
    "CONFIG_KASAN"                          => :disable,
    "CONFIG_UBSAN"                          => :disable,
    "CONFIG_KCSAN"                          => :disable,
    "CONFIG_LOCKDEP"                        => :disable,
    "CONFIG_LOCK_STAT"                      => :disable,
    "CONFIG_DEBUG_LOCK_ALLOC"              => :disable,

    # --- Futex: synchronizacja wątków (esync/fsync baseline) ---
    "CONFIG_FUTEX"                          => :enable,
    "CONFIG_FUTEX_PI"                       => :enable,

    # --- Wydajność I/O ---
    "CONFIG_BLK_WBT"                        => :enable,
    "CONFIG_MQ_IOSCHED_KYBER"              => :enable,
    "CONFIG_BFQ_GROUP_IOSCHED"             => :enable
  }.freeze

  # BORE scheduler — Burst-Oriented Response Enhancer
  # Patch na EEVDF; jeśli patch BORE nie został zastosowany (auto_fetch = false),
  # włączamy CONFIG_SCHED_BORE przez scriptkconfig (jeśli dostępne)
  BORE_OPTIONS = {
    "CONFIG_SCHED_BORE"                     => :enable,
    # Tuning BORE — wartości zoptymalizowane dla gaming/desktop
    # (ignorowane przez kernel jeśli patch BORE nie jest zastosowany)
    "CONFIG_BORE_SCHED_LATENCY_NS"          => "5000000",
    "CONFIG_BORE_SCHED_MIN_GRAN_NS"         => "500000",
    "CONFIG_BORE_SCHED_WAKEUP_GRAN_NS"      => "1500000"
  }.freeze

  # sched_ext — BPF extensible scheduler (zmiana schedulera w runtime)
  SCHED_EXT_OPTIONS = {
    "CONFIG_SCHED_CLASS_EXT"                => :enable,
    "CONFIG_BPF_SYSCALL"                    => :enable,
    "CONFIG_BPF_JIT"                        => :enable,
    "CONFIG_BPF_JIT_ALWAYS_ON"             => :enable
  }.freeze

  # NTSYNC — NT synchronization primitive driver (Wine/Proton)
  # Dostępny od kernel 6.14 w mainline — nie wymaga patcha
  NTSYNC_OPTIONS = {
    "CONFIG_NTSYNC"                         => :enable
  }.freeze

  # BBR v3 — TCP congestion control (niższa latencja sieciowa)
  BBR3_OPTIONS = {
    "CONFIG_TCP_CONG_BBR"                   => :enable,
    "CONFIG_DEFAULT_TCP_CONG"               => '"bbr"',
    "CONFIG_NET_SCH_FQ"                     => :enable,  # Fair Queue — wymagany przez BBR
    "CONFIG_NET_SCH_FQ_CODEL"              => :enable
  }.freeze

  # Valve VRAM opcje CONFIG — fallback gdy patche niedostępne
  VALVE_VRAM_OPTIONS = {
    # Priorytetyzacja pamięci GPU dla gier (dostępne w nowszych kernelach)
    "CONFIG_DRM_TTM_BO_PRIORITY"            => :enable,
    "CONFIG_DRM_AMDGPU_USERPTR"            => :enable,  # AMD GPUVM
    # Eviction tunables
    "CONFIG_DRM_TTM"                        => :enable
  }.freeze

  def apply_gaming_tweaks
    @log.info "Stosowanie bazowych optymalizacji gamingowych..."
    apply_config_options(BASE_GAMING_OPTIONS)

    if @cfg.bore_scheduler?
      @log.info "  → BORE scheduler (CONFIG_SCHED_BORE)..."
      apply_config_options(BORE_OPTIONS)
    end

    if @cfg.sched_ext?
      @log.info "  → sched_ext BPF extensible scheduler..."
      apply_config_options(SCHED_EXT_OPTIONS)
    end

    if @cfg.ntsync?
      kver_minor = @cfg.kernel_version.split(".")[1].to_i
      kver_major = @cfg.kernel_version.split(".")[0].to_i
      if kver_major > 6 || (kver_major == 6 && kver_minor >= 14)
        @log.info "  → NTSYNC (Wine/Proton NT sync driver)..."
        apply_config_options(NTSYNC_OPTIONS)
      else
        @log.warn "  → NTSYNC wymaga kernela >= 6.14 (masz #{@cfg.kernel_version}) — pomijam."
      end
    end

    if @cfg.bbr3?
      @log.info "  → BBR v3 TCP congestion control..."
      apply_config_options(BBR3_OPTIONS)
    end

    if @cfg.valve_vram_patches?
      @log.info "  → Valve VRAM CONFIG opcje (fallback/uzupełnienie patchy)..."
      apply_config_options(VALVE_VRAM_OPTIONS)
    end

    # Optymalizacja O3
    if @cfg.optimize_o3?
      @log.info "  → Kompilacja z -O3..."
      patch_makefile_o3
    end
  end

  def patch_makefile_o3
    makefile = File.join(@src, "Makefile")
    content  = File.read(makefile)
    patched  = content.gsub(/\-O2\b/, "-O3")
    File.write(makefile, patched) unless content == patched
  end

  # ===========================================================================
  # 6. POZIOM CPU (x86-64-v1/v2/v3/v4)
  # ===========================================================================
  def apply_cpu_level
    level = @cfg.cpu_level
    info  = @cfg.cpu_level_info
    @log.info "Ustawianie poziomu CPU: #{level} — #{info[:label]}"

    # Wyłącz wszystkie CONFIG_GENERIC_CPUx
    %w[CONFIG_GENERIC_CPU CONFIG_GENERIC_CPU2 CONFIG_GENERIC_CPU3 CONFIG_GENERIC_CPU4
       CONFIG_MCORE2 CONFIG_MK8 CONFIG_MK10 CONFIG_MNATIVE_INTEL CONFIG_MNATIVE_AMD].each do |k|
      set_config_option(k, :disable)
    end

    # Włącz właściwy poziom
    if info[:kconfig]
      set_config_option(info[:kconfig], :enable)
    else
      # v1 / generic — włącz CONFIG_GENERIC_CPU
      set_config_option("CONFIG_GENERIC_CPU", :enable)
    end

    # Wstrzyknij flagę marcowo do top-level Makefile
    inject_cpu_march_flag(info[:flag])
  end

  def inject_cpu_march_flag(flag)
    makefile = File.join(@src, "Makefile")
    content  = File.read(makefile)

    # Usuń poprzedni wpis LegendaryOS (idempotentność)
    content = content.gsub(/^# LegendaryOS CPU.*\nCFLAGS.*\n/, "")

    # Dodaj za pierwszym KBUILD_CFLAGS lub na końcu sekcji kompilacji
    marker = "KBUILD_CFLAGS"
    if content.include?(marker)
      content = content.sub(
        /^(#{Regexp.escape(marker)}.*)$/,
        "# LegendaryOS CPU: #{flag}\nKCFLAGS += #{flag}\n\\1"
      )
    else
      content << "\n# LegendaryOS CPU: #{flag}\nKCFLAGS += #{flag}\n"
    end

    File.write(makefile, content)
  end

  # ===========================================================================
  # 7. TWEAKI KOMPILATORA (LTO jeśli Clang)
  # ===========================================================================
  def apply_compiler_tweaks
    if @cfg.lto_thin?
      @log.info "Włączanie Thin LTO (Clang)..."
      apply_config_options(
        "CONFIG_LTO_CLANG_THIN"  => :enable,
        "CONFIG_LTO_CLANG_FULL"  => :disable,
        "CONFIG_LTO_NONE"        => :disable
      )
    end
  end

  # ===========================================================================
  # 8. LOCALVERSION
  # ===========================================================================
  def set_localversion
    @log.info "Ustawianie LOCALVERSION=#{@cfg.localversion}"
    set_config_option("CONFIG_LOCALVERSION", "\"#{@cfg.localversion}\"")
    set_config_option("CONFIG_LOCALVERSION_AUTO", :disable)
  end

  # ===========================================================================
  # 9. FINALIZACJA
  # ===========================================================================
  def finalize_config
    @log.info "Uruchamianie make olddefconfig..."
    Utils.run!("make -C #{@src.shellescape} olddefconfig", @log)
    @log.info "Konfiguracja kernela zakończona."
  end

  # ===========================================================================
  # HELPERS
  # ===========================================================================
  def dot_config
    File.join(@src, ".config")
  end

  def apply_config_options(opts)
    opts.each { |key, val| set_config_option(key, val) }
  end

  def set_config_option(key, value)
    content = File.read(dot_config)

    new_line = case value
               when :enable  then "#{key}=y"
               when :disable then "# #{key} is not set"
               when :module  then "#{key}=m"
               else               "#{key}=#{value}"
               end

    pattern = /^(# )?#{Regexp.escape(key)}[= ].*/

    if content.match?(pattern)
      content = content.gsub(pattern, new_line)
    else
      content << "\n#{new_line}\n"
    end

    File.write(dot_config, content)
  end
end
