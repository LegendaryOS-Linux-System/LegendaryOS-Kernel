# frozen_string_literal: true

require "fileutils"
require "erb"
require_relative "utils"

# Generuje specfile RPM i uruchamia rpmbuild.
# Przy instalacji .rpm:
#   %pre    — usuwa stary LegendaryOS kernel z GRUB
#   %post   — dracut initramfs + grubby --make-default + grub2-mkconfig
#   %postun — przy odinstalowaniu przywraca poprzedni kernel
class RpmPackager
  class Error < StandardError; end

  def initialize(cfg, log)
    @cfg      = cfg
    @log      = log
    @staging  = File.join(cfg.build_dir, "staging")
    @rpm_root = File.join(cfg.build_dir, "rpmbuild")
    @spec_dir = File.join(@rpm_root, "SPECS")
    @out_dir  = File.expand_path(cfg.output_dir)
  end

  def write_spec
    FileUtils.mkdir_p(@spec_dir)
    File.write(spec_path, render_spec)
    @log.info "Specfile zapisany: #{spec_path}"
    spec_path
  end

  def build_rpm
    prepare_rpm_tree
    write_spec

    @log.info "Uruchamianie rpmbuild..."
    FileUtils.mkdir_p(@out_dir)

    Utils.run!(
      "rpmbuild -bb #{spec_path.shellescape} " \
      "--define \"_topdir #{@rpm_root}\" " \
      "--define \"_rpmdir #{@out_dir}\"",
      @log
    )

    rpms = Dir[File.join(@out_dir, "**", "*.rpm")]
    raise Error, "rpmbuild nie wygenerował żadnych plików .rpm" if rpms.empty?

    rpms
  end

  private

  def spec_path
    File.join(@spec_dir, "legendaryos-kernel.spec")
  end

  def prepare_rpm_tree
    %w[BUILD BUILDROOT RPMS SOURCES SPECS SRPMS].each do |d|
      FileUtils.mkdir_p(File.join(@rpm_root, d))
    end

    # BUILDROOT nazwa musi pasować do: Name-Version-Release.Arch
    # Version w spec = kernel_version (np. "7.1"), Release = release_tag
    # ale katalog modułów = full_version (np. "7.1-legendaryos")
    buildroot = File.join(
      @rpm_root, "BUILDROOT",
      "legendaryos-kernel-#{@cfg.kernel_version}-#{@cfg.release_tag}.#{@cfg.arch}"
    )
    FileUtils.rm_rf(buildroot)
    FileUtils.cp_r(@staging + "/.", buildroot)
    @log.info "BUILDROOT: #{buildroot}"

    # Zweryfikuj że moduły są w oczekiwanej ścieżce
    mod_path = File.join(buildroot, "lib", "modules", @cfg.full_version)
    unless Dir.exist?(mod_path)
      # Sprawdź co faktycznie jest w lib/modules/
      found = Dir[File.join(buildroot, "lib", "modules", "*")].map { |p| File.basename(p) }
      raise Error, "Brak modułów w #{mod_path}. " \
                   "Znalezione katalogi modułów: #{found.join(', ')}. " \
                   "Sprawdź czy full_version (#{@cfg.full_version}) zgadza się z tym co kernel instaluje."
    end
  end

  # Buduje opis optymalizacji do %description i %changelog
  def feature_list
    features = []
    features << "BORE scheduler (Burst-Oriented Response Enhancer, desktop/gaming preemption)"   if @cfg.bore_scheduler?
    features << "sched_ext — BPF extensible scheduler (zmiana schedulera w runtime)"             if @cfg.sched_ext?
    features << "NTSYNC — NT sync driver, Wine/Proton bez esync/fsync patchy"                   if @cfg.ntsync?
    features << "BBR v3 — niższa latencja TCP w grach online"                                    if @cfg.bbr3?
    features << "Valve VRAM patch set — priorytet pamięci gier, mniej OOM przy pełnym VRAM"     if @cfg.valve_vram_patches?
    features << "CPU target: #{@cfg.cpu_level_label}"
    features << "Kompilacja z -O3"                                                               if @cfg.optimize_o3?
    features << "Thin LTO (Clang)"                                                               if @cfg.lto_thin?
    features << "HZ=1000, PREEMPT, Multi-Gen LRU, ZRAM, ZSWAP"
    features << "NVIDIA akmod: podpisywanie modułów wyłączone, KALLSYMS_ALL, DMABUF_HEAPS, ReBAR" if @cfg.nvidia_enabled?
    features << "Nouveau wyłączony"                                                              if @cfg.nvidia_enabled?
    features
  end

  def render_spec
    cfg      = @cfg
    features = feature_list
    ERB.new(SPEC_TEMPLATE, trim_mode: "-").result(binding)
  end

  SPEC_TEMPLATE = <<~'SPEC'
    Name:           legendaryos-kernel
    Version:        <%= cfg.kernel_version %>
    Release:        <%= cfg.release_tag %>%{?dist}
    Summary:        LegendaryOS Kernel <%= cfg.kernel_version %> — Gaming/NVIDIA (BORE, NTSYNC, sched_ext, BBR v3)
    License:        GPL-2.0-only
    URL:            https://github.com/<%= cfg.github_owner %>/<%= cfg.github_repo %>
    ExclusiveArch:  <%= cfg.arch %>

    Requires(post): grubby
    Requires(post): dracut
    Requires(post): coreutils

    Provides:       legendaryos-kernel = %{version}-%{release}
    Provides:       kernel = %{version}-%{release}
    Obsoletes:      legendaryos-kernel < %{version}

    # Nie przerywaj buildu gdy rpmbuild znajdzie pliki nieuwzględnione w %files.
    # Wszystkie moduły .ko są pakowane przez wildcard /lib/modules/%%{kver}/**
    %define _unpackaged_files_terminate_build 0

    %description
    LegendaryOS Kernel — jądro Linuxa dla dystrybucji LegendaryOS (Fedora-based).
    Zoptymalizowane pod gaming i sterowniki NVIDIA proprietary (akmod-nvidia).

    Aktywne optymalizacje tej kompilacji:
    <% features.each do |f| -%>
      • <%= f %>
    <% end -%>

    CPU target: <%= cfg.cpu_level_label %>
    Źródła: Linux <%= cfg.kernel_version %><%= cfg.localversion %>

    # ==========================================================================
    # %install — generuj listę plików przez find (wildcard ** nie działa w rpmbuild)
    # ==========================================================================
    %install
    rm -f %{_builddir}/filelist.txt

    # /boot
    echo "/boot/<%= cfg.kernel_image_name %>-<%= cfg.full_version %>" >> %{_builddir}/filelist.txt
    [ -f "%{buildroot}/boot/System.map-<%= cfg.full_version %>" ] && \
      echo "/boot/System.map-<%= cfg.full_version %>" >> %{_builddir}/filelist.txt || true
    echo "/boot/config-<%= cfg.full_version %>" >> %{_builddir}/filelist.txt

    # /lib/modules — find zamiast wildcard
    echo "%dir /lib/modules/<%= cfg.full_version %>" >> %{_builddir}/filelist.txt
    find %{buildroot}/lib/modules/<%= cfg.full_version %> -mindepth 1 \
      \( -type f -o -type l \) \
      -printf "/lib/modules/<%= cfg.full_version %>/%P\n" >> %{_builddir}/filelist.txt

    %files -f %{_builddir}/filelist.txt
    %defattr(-,root,root,-)

    # ==========================================================================
    # %pre — usuń stary LegendaryOS kernel z GRUBa przed instalacją nowego
    # ==========================================================================
    %pre
    OLD_VMLINUZ=$(ls /boot/vmlinuz-*legendaryos* 2>/dev/null | head -1)
    if [ -n "$OLD_VMLINUZ" ] && [ "$OLD_VMLINUZ" != "/boot/vmlinuz-<%= cfg.full_version %>" ]; then
        echo "[LegendaryOS] Usuwanie starego kernela z GRUB: $OLD_VMLINUZ"
        grubby --remove-kernel="$OLD_VMLINUZ" 2>/dev/null || true
        OLD_VER=$(basename "$OLD_VMLINUZ" | sed 's/vmlinuz-//')
        OLD_INITRD="/boot/initramfs-${OLD_VER}.img"
        [ -f "$OLD_INITRD" ] && rm -f "$OLD_INITRD" && echo "[LegendaryOS] Usunięto stary initramfs: $OLD_INITRD"
    fi

    # ==========================================================================
    # %post — initramfs + rejestracja w GRUB + ustaw jako domyślny
    # ==========================================================================
    %post
    set -e

    KVER="<%= cfg.full_version %>"
    VMLINUZ="/boot/vmlinuz-${KVER}"
    INITRD="/boot/initramfs-${KVER}.img"

    # --- 1. Generuj initramfs ---
    echo "[LegendaryOS] Generowanie initramfs dla ${KVER}..."
    dracut --force \
           --kver "${KVER}" \
           --add "kernel-modules kernel-modules-extra" \
           "${INITRD}" \
           "${KVER}"

    # --- 2. Rejestracja w GRUB (grubby) ---
    echo "[LegendaryOS] Rejestrowanie w GRUB..."

    # Pobierz cmdline z aktualnie domyślnego kernela (zachowaj parametry użytkownika)
    CURRENT_ARGS=$(grubby --info=DEFAULT 2>/dev/null | grep '^args=' | head -1 | sed 's/^args=//' | tr -d '"')

    # Dodaj parametry NVIDIA jeśli nie ma ich jeszcze
    for PARAM in "nvidia-drm.modeset=1" "iomem=relaxed"; do
        echo "$CURRENT_ARGS" | grep -qF "$PARAM" || CURRENT_ARGS="${CURRENT_ARGS} ${PARAM}"
    done

    grubby --add-kernel="${VMLINUZ}" \
           --initrd="${INITRD}" \
           --title="LegendaryOS Kernel <%= cfg.kernel_version %>" \
           --args="${CURRENT_ARGS}" \
           --make-default

    # --- 3. Ustaw jako domyślny ---
    echo "[LegendaryOS] Ustawianie jako domyślny kernel..."
    grubby --set-default="${VMLINUZ}"

    # --- 4. Aktualizuj grub.cfg (EFI + BIOS) ---
    if [ -d /sys/firmware/efi ]; then
        EFI_GRUB=""
        for P in /boot/efi/EFI/fedora/grub.cfg /boot/efi/EFI/LegendaryOS/grub.cfg; do
            [ -f "$P" ] && EFI_GRUB="$P" && break
        done
        if [ -n "$EFI_GRUB" ]; then
            echo "[LegendaryOS] Aktualizacja EFI grub.cfg: $EFI_GRUB"
            grub2-mkconfig -o "$EFI_GRUB" 2>/dev/null || true
        fi
    fi
    if [ -f /boot/grub2/grub.cfg ]; then
        echo "[LegendaryOS] Aktualizacja BIOS grub.cfg..."
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    fi

    # --- 5. Poinformuj o BORE / sched_ext ---
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         LegendaryOS Kernel <%= cfg.kernel_version %> zainstalowany!          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  • BORE scheduler  • NTSYNC  • BBR v3  • sched_ext         ║"
    echo "║  • CPU: <%= cfg.cpu_level_label.to_s[0..45].ljust(46) %>  ║"
    echo "║  Uruchom ponownie, aby załadować nowe jądro.                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # ==========================================================================
    # %postun — przywróć poprzedni kernel po odinstalowaniu
    # ==========================================================================
    %postun
    if [ $1 -eq 0 ]; then
        VMLINUZ="/boot/vmlinuz-<%= cfg.full_version %>"
        echo "[LegendaryOS] Odinstalowywanie kernela <%= cfg.full_version %>..."

        grubby --remove-kernel="${VMLINUZ}" 2>/dev/null || true

        # Usuń initramfs
        rm -f "/boot/initramfs-<%= cfg.full_version %>.img" 2>/dev/null || true
        rm -f "/boot/initramfs-<%= cfg.full_version %>-rescue.img" 2>/dev/null || true

        # Przywróć ostatni dostępny kernel jako domyślny
        LATEST_VMLINUZ=$(grubby --info=ALL 2>/dev/null \
            | grep '^kernel=' | grep -v legendaryos | head -1 \
            | cut -d= -f2 | tr -d '"')
        if [ -n "$LATEST_VMLINUZ" ] && [ -f "$LATEST_VMLINUZ" ]; then
            grubby --set-default="$LATEST_VMLINUZ"
            echo "[LegendaryOS] Przywrócono domyślny kernel: $LATEST_VMLINUZ"
        else
            # Fallback: pierwsza dostępna pozycja GRUB
            FALLBACK=$(grubby --info=ALL 2>/dev/null | grep '^kernel=' | head -1 | cut -d= -f2 | tr -d '"')
            [ -n "$FALLBACK" ] && grubby --set-default="$FALLBACK"
        fi

        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
        if [ -d /sys/firmware/efi ]; then
            for P in /boot/efi/EFI/fedora/grub.cfg /boot/efi/EFI/LegendaryOS/grub.cfg; do
                [ -f "$P" ] && grub2-mkconfig -o "$P" 2>/dev/null || true
            done
        fi

        echo "[LegendaryOS] Kernel <%= cfg.full_version %> usunięty. Uruchom ponownie system."
    fi

    %changelog
    * <%= Time.now.strftime("%a %b %d %Y") %> LegendaryOS Build System <build@legendaryos.linux> - <%= cfg.kernel_version %>-<%= cfg.release_tag %>
    - LegendaryOS Kernel <%= cfg.kernel_version %> — Gaming kernel dla Fedory
    <% features.each do |f| -%>
    - <%= f %>
    <% end -%>
  SPEC
end
