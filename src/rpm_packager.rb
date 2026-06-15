# frozen_string_literal: true

require "fileutils"
require "erb"
require_relative "utils"

# Generuje specfile RPM i uruchamia rpmbuild.
# Wygenerowany pakiet przy instalacji:
#   - usuwa stare jądro LegendaryOS
#   - instaluje nowe
#   - ustawia je jako domyślne w GRUB
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

  # Generuje i zwraca ścieżkę do specfile
  def write_spec
    FileUtils.mkdir_p(@spec_dir)
    path = spec_path
    File.write(path, render_spec)
    @log.info "Specfile zapisany: #{path}"
    path
  end

  # Buduje RPM i zwraca listę wygenerowanych plików .rpm
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

  # -------------------------------------------------------------------------
  # Przygotowanie drzewa rpmbuild
  # -------------------------------------------------------------------------
  def prepare_rpm_tree
    %w[BUILD BUILDROOT RPMS SOURCES SPECS SRPMS].each do |d|
      FileUtils.mkdir_p(File.join(@rpm_root, d))
    end

    # Skopiuj staging jako BUILDROOT
    buildroot = File.join(@rpm_root, "BUILDROOT",
                          "legendaryos-kernel-#{@cfg.kernel_version}-#{@cfg.release_tag}.#{@cfg.arch}")
    FileUtils.rm_rf(buildroot)
    FileUtils.cp_r(@staging, buildroot)
  end

  # -------------------------------------------------------------------------
  # Specfile (ERB template)
  # -------------------------------------------------------------------------
  def render_spec
    cfg      = @cfg
    template = SPEC_TEMPLATE
    ERB.new(template, trim_mode: "-").result(binding)
  end

  SPEC_TEMPLATE = <<~'SPEC'
    Name:           legendaryos-kernel
    Version:        <%= cfg.kernel_version %>
    Release:        <%= cfg.release_tag %>%{?dist}
    Summary:        LegendaryOS Linux Kernel <%= cfg.kernel_version %> zoptymalizowany pod NVIDIA akmod
    License:        GPL-2.0-only
    URL:            https://github.com/<%= cfg.github_owner %>/<%= cfg.github_repo %>
    ExclusiveArch:  <%= cfg.arch %>

    # Wymagane przez akmod-nvidia
    Requires:       kernel-core = %{version}-%{release}
    Requires(post): grubby
    Requires(post): dracut

    # Konflikt ze zwykłym kernelem Fedory (opcjonalne — zakomentuj jeśli chcesz koegzystencję)
    # Conflicts: kernel

    # Usuń stary LegendaryOS kernel przed instalacją nowego
    Provides:       legendaryos-kernel = %{version}
    Obsoletes:      legendaryos-kernel < %{version}

    %description
    LegendaryOS Kernel – własne jądro Linuxa zbudowane dla dystrybucji LegendaryOS.
    Optymalizowane pod sterowniki NVIDIA proprietary (akmod-nvidia):
      • Podpisywanie modułów wyłączone (kompatybilność akmod bez Secure Boot)
      • CONFIG_KALLSYMS_ALL=y
      • CONFIG_DMABUF_HEAPS=y (NVIDIA GSP firmware)
      • Preempt desktop, HZ=1000
      • Skompilowane z -O3
      • Nouveau wyłączony
    Wersja źródeł: Linux <%= cfg.kernel_version %><%= cfg.localversion %>

    # -----------------------------------------------------------------------
    # Pliki (staging → /boot + /lib/modules)
    # -----------------------------------------------------------------------
    %files
    %defattr(-,root,root,-)
    /boot/vmlinuz-<%= cfg.full_version %>
    /boot/System.map-<%= cfg.full_version %>
    /boot/config-<%= cfg.full_version %>
    /lib/modules/<%= cfg.full_version %>/

    # -----------------------------------------------------------------------
    # Przed instalacją: usuń stary LegendaryOS kernel (jeśli istnieje)
    # -----------------------------------------------------------------------
    %pre
    if [ $1 -gt 1 ]; then
        OLD_VER=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' legendaryos-kernel 2>/dev/null | head -1)
        if [ -n "$OLD_VER" ]; then
            echo "[LegendaryOS] Usuwanie starego kernela: $OLD_VER"
            OLD_VMLINUZ=$(ls /boot/vmlinuz-*legendaryos* 2>/dev/null | head -1)
            if [ -n "$OLD_VMLINUZ" ]; then
                grubby --remove-kernel="$OLD_VMLINUZ" || true
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # Po instalacji: regeneruj initramfs, dodaj do GRUB i ustaw jako domyślny
    # -----------------------------------------------------------------------
    %post
    KERNEL_VERSION="<%= cfg.full_version %>"
    VMLINUZ="/boot/vmlinuz-${KERNEL_VERSION}"
    INITRD="/boot/initramfs-${KERNEL_VERSION}.img"

    echo "[LegendaryOS] Generowanie initramfs dla ${KERNEL_VERSION}..."
    dracut --force "${INITRD}" "${KERNEL_VERSION}"

    echo "[LegendaryOS] Rejestrowanie kernela w GRUB..."
    grubby --add-kernel="${VMLINUZ}" \
           --initrd="${INITRD}" \
           --title="LegendaryOS Kernel <%= cfg.kernel_version %>" \
           --copy-default \
           --make-default

    echo "[LegendaryOS] Ustawianie jako domyślny kernel..."
    grubby --set-default="${VMLINUZ}"

    # Aktualizuj grub.cfg (EFI + BIOS)
    if [ -f /boot/grub2/grub.cfg ]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    fi
    if [ -f /boot/efi/EFI/fedora/grub.cfg ]; then
        grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true
    fi

    echo "[LegendaryOS] Kernel <%= cfg.full_version %> zainstalowany i ustawiony jako domyślny."
    echo "[LegendaryOS] Uruchom ponownie system, aby go załadować."

    # -----------------------------------------------------------------------
    # Po odinstalowaniu: przywróć poprzedni kernel
    # -----------------------------------------------------------------------
    %postun
    if [ $1 -eq 0 ]; then
        echo "[LegendaryOS] Usuwanie kernela <%= cfg.full_version %> z GRUB..."
        grubby --remove-kernel="/boot/vmlinuz-<%= cfg.full_version %>" || true

        # Ustaw jako domyślny najnowszy dostępny kernel
        LATEST=$(grubby --info=ALL 2>/dev/null | grep "^kernel=" | head -1 | cut -d= -f2 | tr -d '"')
        if [ -n "$LATEST" ]; then
            grubby --set-default="$LATEST"
            echo "[LegendaryOS] Przywrócono domyślny kernel: $LATEST"
        fi

        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
        grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true
    fi

    %changelog
    * <%= Time.now.strftime("%a %b %d %Y") %> LegendaryOS Build System <build@legendaryos.linux> - <%= cfg.kernel_version %>-<%= cfg.release_tag %>
    - LegendaryOS Kernel <%= cfg.kernel_version %> zoptymalizowany pod NVIDIA akmod
    - Kompilacja z -O3, HZ=1000, PREEMPT, Nouveau wyłączony
  SPEC
end
