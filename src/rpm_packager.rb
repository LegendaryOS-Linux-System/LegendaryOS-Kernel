# frozen_string_literal: true

require "fileutils"
require "erb"
require_relative "utils"

# Generuje specfile RPM i uruchamia rpmbuild.
# Strategia pakowania:
#   - Pliki ze staging/ kopiowane do BUILDROOT przez Ruby (prepare_rpm_tree)
#   - Lista plików generowana przez Ruby (generate_filelist) i wstawiana
#     do %files jako literał — bez %install, bez wildcard, bez find w spec
#   - rpmbuild dostaje gotowy BUILDROOT i nie rusza go wcale
#     (__spec_install_pre ustawione na nil żeby nie czyścił)
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

  def build_rpm
    prepare_rpm_tree   # kopiuje staging → BUILDROOT, wykrywa actual_kver
    generate_filelist  # skanuje BUILDROOT i buduje listę plików
    write_spec         # renderuje spec z literalną listą plików
    run_rpmbuild
  end

  private

  # ============================================================================
  # 1. Przygotowanie BUILDROOT
  # ============================================================================
  def prepare_rpm_tree
    %w[BUILD BUILDROOT RPMS SOURCES SPECS SRPMS].each do |d|
      FileUtils.mkdir_p(File.join(@rpm_root, d))
    end

    @buildroot = File.join(
      @rpm_root, "BUILDROOT",
      "legendaryos-kernel-#{@cfg.kernel_version}-#{@cfg.release_tag}.#{@cfg.arch}"
    )

    # Usuń poprzedni buildroot i skopiuj świeże staging
    FileUtils.rm_rf(@buildroot)
    FileUtils.cp_r("#{@staging}/.", @buildroot)
    @log.info "BUILDROOT: #{@buildroot}"

    # Wykryj rzeczywisty katalog modułów
    # (kernel może zmienić 7.1 → 7.1.0 przy kompilacji)
    mod_dirs = Dir[File.join(@buildroot, "lib", "modules", "*legendaryos*")]
    if mod_dirs.empty?
      found = Dir[File.join(@buildroot, "lib", "modules", "*")].map { |p| File.basename(p) }
      raise Error, "Brak katalogu *legendaryos* w BUILDROOT/lib/modules/. " \
                   "Znalezione: #{found.join(', ')}"
    end
    @actual_kver = File.basename(mod_dirs.first)
    @log.info "Wykryty katalog modułów: #{@actual_kver}"

    # Wykryj obraz kernela
    boot_images = Dir[File.join(@buildroot, "boot", "#{@cfg.kernel_image_name}-*")]
    if boot_images.empty?
      found = Dir[File.join(@buildroot, "boot", "*")].map { |p| File.basename(p) }
      raise Error, "Brak obrazu #{@cfg.kernel_image_name}-* w BUILDROOT/boot/. " \
                   "Znalezione: #{found.join(', ')}"
    end
    @kernel_image = File.basename(boot_images.first)
    @log.info "Wykryty obraz kernela: #{@kernel_image}"
  end

  # ============================================================================
  # 2. Generowanie listy plików w Ruby (skanowanie BUILDROOT)
  #    Wynik to tablica stringów "/ścieżka/do/pliku" gotowa do wklejenia w %files
  # ============================================================================
  def generate_filelist
    @filelist = []

    # /boot
    @filelist << "/boot/#{@kernel_image}"
    sysmap = File.join(@buildroot, "boot", "System.map-#{@actual_kver}")
    @filelist << "/boot/System.map-#{@actual_kver}" if File.exist?(sysmap)
    config = File.join(@buildroot, "boot", "config-#{@actual_kver}")
    @filelist << "/boot/config-#{@actual_kver}" if File.exist?(config)

    # /lib/modules — rekurencyjnie, wszystkie pliki i symlinki
    mod_root = File.join(@buildroot, "lib", "modules", @actual_kver)
    @filelist << "%dir /lib/modules/#{@actual_kver}"

    Find_files(mod_root).each do |abs_path|
      rel = abs_path.sub(@buildroot, "")
      @filelist << rel
    end

    @log.info "Wygenerowano listę #{@filelist.size} plików/katalogów do %files"
    @filelist
  end

  # Pomocnik: zwraca wszystkie pliki i symlinki rekurencyjnie
  def Find_files(dir)
    results = []
    return results unless Dir.exist?(dir)
    Dir.glob("#{dir}/**/*", File::FNM_DOTMATCH).each do |path|
      next if File.basename(path) == "." || File.basename(path) == ".."
      results << path if File.file?(path) || File.symlink?(path)
    end
    results.sort
  end

  # ============================================================================
  # 3. Spec file
  # ============================================================================
  def spec_path
    File.join(@spec_dir, "legendaryos-kernel.spec")
  end

  def write_spec
    FileUtils.mkdir_p(@spec_dir)
    File.write(spec_path, render_spec)
    @log.info "Specfile zapisany: #{spec_path}"
  end

  def render_spec
    cfg      = @cfg
    kver     = @actual_kver
    img      = @kernel_image
    features = feature_list
    filelist = @filelist
    ERB.new(SPEC_TEMPLATE, trim_mode: "-").result(binding)
  end

  def feature_list
    features = []
    features << "BORE scheduler (Burst-Oriented Response Enhancer)"  if @cfg.bore_scheduler?
    features << "sched_ext — BPF extensible scheduler"               if @cfg.sched_ext?
    features << "NTSYNC — NT sync driver (Wine/Proton)"              if @cfg.ntsync?
    features << "BBR v3 — niższa latencja TCP"                       if @cfg.bbr3?
    features << "Valve VRAM patch set"                               if @cfg.valve_vram_patches?
    features << "CPU target: #{@cfg.cpu_level_label}"
    features << "Kompilacja z -O3"                                   if @cfg.optimize_o3?
    features << "Thin LTO (Clang)"                                   if @cfg.lto_thin?
    features << "HZ=1000, PREEMPT, Multi-Gen LRU, ZRAM, ZSWAP"
    features << "NVIDIA akmod: KALLSYMS_ALL, DMABUF_HEAPS, ReBAR"   if @cfg.nvidia_enabled?
    features << "Nouveau wyłączony"                                  if @cfg.nvidia_enabled?
    features
  end

  # ============================================================================
  # 4. rpmbuild
  # ============================================================================
  def run_rpmbuild
    @log.info "Uruchamianie rpmbuild..."
    FileUtils.mkdir_p(@out_dir)

    Utils.run!(
      "rpmbuild -bb #{spec_path.shellescape} " \
      "--define \"_topdir #{@rpm_root}\" " \
      "--define \"_rpmdir #{@out_dir}\" " \
      "--define \"_builddir #{File.join(@rpm_root, 'BUILD')}\"",
      @log
    )

    rpms = Dir[File.join(@out_dir, "**", "*.rpm")]
    raise Error, "rpmbuild nie wygenerował żadnych plików .rpm" if rpms.empty?
    rpms
  end

  # ============================================================================
  # SPEC TEMPLATE
  # Nie zawiera %install — BUILDROOT jest już wypełniony przez Ruby.
  # %define __spec_install_pre %{nil} zapobiega czyszczeniu BUILDROOT przez rpmbuild.
  # %files zawiera literalną listę plików wygenerowaną przez Ruby (generate_filelist).
  # ============================================================================
  SPEC_TEMPLATE = <<~'SPEC'
    Name:           legendaryos-kernel
    Version:        <%= cfg.kernel_version %>
    Release:        <%= cfg.release_tag %>%{?dist}
    Summary:        LegendaryOS Kernel <%= cfg.kernel_version %> — Gaming (BORE, NTSYNC, sched_ext, BBR v3)
    License:        GPL-2.0-only
    URL:            https://github.com/<%= cfg.github_owner %>/<%= cfg.github_repo %>
    ExclusiveArch:  <%= cfg.arch %>

    Requires(post): grubby
    Requires(post): dracut
    Requires(post): coreutils

    Provides:       legendaryos-kernel = %{version}-%{release}
    Provides:       kernel = %{version}-%{release}
    Obsoletes:      legendaryos-kernel < %{version}

    # Nie czyść BUILDROOT — jest już wypełniony przez Ruby przed rpmbuild
    %define __spec_install_pre %{nil}
    %define _unpackaged_files_terminate_build 0

    %description
    LegendaryOS Kernel — jądro Linuxa dla dystrybucji LegendaryOS (Fedora-based).
    Zoptymalizowane pod gaming i sterowniki NVIDIA proprietary (akmod-nvidia).

    Aktywne optymalizacje:
    <% features.each do |f| -%>
      * <%= f %>
    <% end -%>

    CPU target: <%= cfg.cpu_level_label %>

    %files
    %defattr(-,root,root,-)
    <% filelist.each do |f| -%>
    <%= f %>
    <% end -%>

    %pre
    OLD_VMLINUZ=$(ls /boot/<%= cfg.kernel_image_name %>-*legendaryos* 2>/dev/null | grep -v "<%= img %>" | head -1)
    if [ -n "$OLD_VMLINUZ" ]; then
        echo "[LegendaryOS] Usuwanie starego kernela z GRUB: $OLD_VMLINUZ"
        grubby --remove-kernel="$OLD_VMLINUZ" 2>/dev/null || true
        OLD_VER=$(basename "$OLD_VMLINUZ" | sed 's/<%= cfg.kernel_image_name %>-//')
        rm -f "/boot/initramfs-${OLD_VER}.img" 2>/dev/null || true
    fi

    %post
    set -e
    KVER="<%= kver %>"
    VMLINUZ="/boot/<%= img %>"
    INITRD="/boot/initramfs-${KVER}.img"

    echo "[LegendaryOS] Generowanie initramfs dla ${KVER}..."
    dracut --force --kver "${KVER}" --add "kernel-modules kernel-modules-extra" "${INITRD}" "${KVER}"

    echo "[LegendaryOS] Rejestrowanie w GRUB..."
    CURRENT_ARGS=$(grubby --info=DEFAULT 2>/dev/null | grep '^args=' | head -1 | sed 's/^args=//' | tr -d '"')
    for PARAM in "nvidia-drm.modeset=1" "iomem=relaxed"; do
        echo "$CURRENT_ARGS" | grep -qF "$PARAM" || CURRENT_ARGS="${CURRENT_ARGS} ${PARAM}"
    done

    grubby --add-kernel="${VMLINUZ}" \
           --initrd="${INITRD}" \
           --title="LegendaryOS Kernel <%= cfg.kernel_version %>" \
           --args="${CURRENT_ARGS}" \
           --make-default

    grubby --set-default="${VMLINUZ}"

    if [ -d /sys/firmware/efi ]; then
        for P in /boot/efi/EFI/fedora/grub.cfg /boot/efi/EFI/LegendaryOS/grub.cfg; do
            [ -f "$P" ] && grub2-mkconfig -o "$P" 2>/dev/null || true
        done
    fi
    [ -f /boot/grub2/grub.cfg ] && grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

    echo ""
    echo "============================================================"
    echo "  LegendaryOS Kernel <%= cfg.kernel_version %> zainstalowany!"
    echo "  BORE, NTSYNC, BBR v3, sched_ext aktywne."
    echo "  Uruchom ponownie system."
    echo "============================================================"

    %postun
    if [ $1 -eq 0 ]; then
        grubby --remove-kernel="/boot/<%= img %>" 2>/dev/null || true
        rm -f "/boot/initramfs-<%= kver %>.img" 2>/dev/null || true
        rm -f "/boot/initramfs-<%= kver %>-rescue.img" 2>/dev/null || true

        LATEST=$(grubby --info=ALL 2>/dev/null \
            | grep '^kernel=' | grep -v legendaryos | head -1 \
            | cut -d= -f2 | tr -d '"')
        [ -n "$LATEST" ] && [ -f "$LATEST" ] && grubby --set-default="$LATEST" || true

        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
        echo "[LegendaryOS] Kernel <%= kver %> usunięty."
    fi

    %changelog
    * <%= Time.now.strftime("%a %b %d %Y") %> LegendaryOS Build System <build@legendaryos.linux> - <%= cfg.kernel_version %>-<%= cfg.release_tag %>
    - LegendaryOS Kernel <%= cfg.kernel_version %>
    <% features.each do |f| -%>
    - <%= f %>
    <% end -%>
  SPEC
end
