#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "src")

require "optparse"
require "logger"

require "config_loader"
require "kernel_fetcher"
require "kernel_configurator"
require "kernel_builder"
require "rpm_packager"
require "github_releaser"
require "utils"

# ---------------------------------------------------------------------------
# Parsowanie argumentów
# ---------------------------------------------------------------------------
options = {
  config_path:    File.join(__dir__, "config.toml"),
  release:        false,
  skip_download:  false,
  skip_build:     false,
  only_spec:      false
}

OptionParser.new do |opts|
  opts.banner = "Użycie: ruby build.rb [opcje]"

  opts.on("--config PATH", "Ścieżka do config.toml") { |v| options[:config_path] = v }
  opts.on("--release",     "Utwórz GitHub Release po budowie") { options[:release] = true }
  opts.on("--skip-download", "Pomiń pobieranie źródeł")        { options[:skip_download] = true }
  opts.on("--skip-build",    "Pomiń kompilację kernela")        { options[:skip_build] = true }
  opts.on("--only-spec",     "Tylko wygeneruj specfile")        { options[:only_spec] = true }
  opts.on("--help", "Wyświetl pomoc") { puts opts; exit 0 }
end.parse!

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------
LOG = Logger.new($stdout)
LOG.formatter = proc do |severity, _time, _prog, msg|
  color = { "INFO" => "\e[32m", "WARN" => "\e[33m", "ERROR" => "\e[31m", "FATAL" => "\e[35m" }
  reset = "\e[0m"
  "#{color.fetch(severity, '')}[#{severity}]#{reset} #{msg}\n"
end
LOG.level = Logger::INFO

# ---------------------------------------------------------------------------
# Główny pipeline
# ---------------------------------------------------------------------------
begin
  LOG.info "=== LegendaryOS Kernel Build System ==="

  # 1. Wczytaj konfigurację
  cfg = ConfigLoader.load(options[:config_path])
  LOG.info "Kernel: #{cfg.kernel_version}#{cfg.localversion}  |  arch: #{cfg.arch}"

  # 2. Pobierz źródła
  unless options[:skip_download]
    LOG.info "--- Pobieranie źródeł kernel.org ---"
    KernelFetcher.new(cfg, LOG).fetch
  end

  if options[:only_spec]
    LOG.info "--- Generowanie specfile (--only-spec) ---"
    RpmPackager.new(cfg, LOG).write_spec
    LOG.info "Specfile zapisany. Koniec."
    exit 0
  end

  # 3. Skonfiguruj kernel (.config)
  unless options[:skip_build]
    LOG.info "--- Konfiguracja jądra ---"
    KernelConfigurator.new(cfg, LOG).configure
  end

  # 4. Skompiluj
  unless options[:skip_build]
    LOG.info "--- Kompilacja jądra ---"
    KernelBuilder.new(cfg, LOG).build
  end

  # 5. Spakuj do RPM
  LOG.info "--- Pakowanie RPM ---"
  pkger   = RpmPackager.new(cfg, LOG)
  rpms    = pkger.build_rpm

  LOG.info "Gotowe RPM:"
  rpms.each { |r| LOG.info "  #{r}" }

  # 6. GitHub Release (opcjonalnie)
  if options[:release]
    LOG.info "--- Tworzenie GitHub Release v#{cfg.kernel_version} ---"
    GithubReleaser.new(cfg, LOG).release(rpms)
  end

  LOG.info "=== SUKCES ==="

rescue ConfigLoader::Error => e
  LOG.error "Błąd konfiguracji: #{e.message}"
  exit 1
rescue KernelFetcher::Error => e
  LOG.error "Błąd pobierania: #{e.message}"
  exit 2
rescue KernelBuilder::Error => e
  LOG.error "Błąd kompilacji: #{e.message}"
  exit 3
rescue RpmPackager::Error => e
  LOG.error "Błąd pakowania RPM: #{e.message}"
  exit 4
rescue GithubReleaser::Error => e
  LOG.error "Błąd GitHub Release: #{e.message}"
  exit 5
rescue Interrupt
  LOG.warn "Przerwano przez użytkownika."
  exit 130
end
