# frozen_string_literal: true

require "fileutils"
require_relative "utils"

# Pobiera tarball źródeł Linuxa z kernel.org i weryfikuje podpis SHA256.
class KernelFetcher
  class Error < StandardError; end

  KERNEL_ORG_BASE = "https://cdn.kernel.org/pub/linux/kernel"

  def initialize(cfg, log)
    @cfg = cfg
    @log = log
  end

  def fetch
    FileUtils.mkdir_p(@cfg.build_dir)

    tarball   = tarball_path
    sha256url = "#{remote_base}/sha256sums.asc"

    if File.exist?(tarball) && !@cfg.clean_build?
      @log.info "Tarball już istnieje, pomijam pobieranie: #{tarball}"
    else
      download_tarball(tarball)
    end

    verify_checksum(tarball, sha256url)
    extract(tarball)
  end

  private

  def version_major
    @cfg.kernel_version.split(".").first
  end

  def remote_base
    "#{KERNEL_ORG_BASE}/v#{version_major}.x"
  end

  def tarball_name
    "linux-#{@cfg.kernel_version}.tar.xz"
  end

  def tarball_path
    File.join(@cfg.build_dir, tarball_name)
  end

  def download_tarball(dest)
    url = "#{remote_base}/#{tarball_name}"
    @log.info "Pobieranie: #{url}"
    Utils.run!("curl -L --progress-bar -o #{dest.shellescape} #{url.shellescape}", @log)
  end

  def verify_checksum(tarball, sha256url)
    @log.info "Weryfikacja SHA-256..."
    sha_file = File.join(@cfg.build_dir, "sha256sums.asc")
    Utils.run!("curl -L -s -o #{sha_file.shellescape} #{sha256url.shellescape}", @log)

    expected = File.readlines(sha_file)
                   .map(&:strip)
                   .find { |l| l.end_with?(tarball_name) }
                   &.split&.first

    raise Error, "Nie znaleziono sumy kontrolnej dla #{tarball_name}" unless expected

    actual = `sha256sum #{tarball.shellescape}`.split.first.strip
    raise Error, "SHA-256 nie zgadza się!\n  oczekiwano: #{expected}\n  otrzymano:  #{actual}" unless actual == expected

    @log.info "SHA-256 OK: #{actual}"
  end

  def extract(tarball)
    dest = @cfg.source_dir
    if Dir.exist?(dest) && !@cfg.clean_build?
      @log.info "Katalog źródeł już istnieje: #{dest}"
      return
    end

    @log.info "Rozpakowywanie #{tarball} → #{@cfg.build_dir}"
    FileUtils.rm_rf(dest)
    Utils.run!("tar -xf #{tarball.shellescape} -C #{@cfg.build_dir.shellescape}", @log)
    @log.info "Źródła gotowe: #{dest}"
  end
end
