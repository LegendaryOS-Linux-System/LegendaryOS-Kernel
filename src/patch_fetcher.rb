# frozen_string_literal: true

require "fileutils"
require "net/http"
require "uri"
require_relative "utils"

# Pobiera wbudowane patche gamingowe z GitHub:
#   - BORE scheduler (firelzrd/bore-scheduler)
#   - Valve VRAM patch set
#
# Patche są zapisywane do build_dir/auto-patches/ i stosowane
# PRZED patchami użytkownika z patches/.
class PatchFetcher
  class Error < StandardError; end

  # Katalog gdzie trafiają auto-pobrane patche
  def self.auto_patches_dir(cfg)
    File.join(cfg.build_dir, "auto-patches")
  end

  def initialize(cfg, log)
    @cfg      = cfg
    @log      = log
    @dest_dir = self.class.auto_patches_dir(cfg)
  end

  # Pobiera wszystkie włączone patche; zwraca posortowaną listę plików .patch
  def fetch_all
    FileUtils.mkdir_p(@dest_dir)
    patches = []

    patches += fetch_bore      if @cfg.bore_scheduler? && @cfg.auto_fetch_patches?
    patches += fetch_valve_vram if @cfg.valve_vram_patches? && @cfg.auto_fetch_patches?

    patches.sort
  end

  private

  # -------------------------------------------------------------------------
  # BORE Scheduler
  # BORE patches są publikowane jako pojedynczy plik per wersja kernela
  # na https://github.com/firelzrd/bore-scheduler
  # -------------------------------------------------------------------------
  def fetch_bore
    @log.info "Pobieranie BORE scheduler patch..."

    # Próbuj dopasować do wersji kernela — major.minor
    kver = @cfg.kernel_version.split(".")[0..1].join(".")

    # Lista kandydatów URL (od najbardziej do najmniej specyficznego)
    candidates = [
      "https://raw.githubusercontent.com/firelzrd/bore-scheduler/main/patches/stable/linux-#{kver}-bore/0001-linux#{kver}.y-bore#{bore_tag}.patch",
      "https://raw.githubusercontent.com/firelzrd/bore-scheduler/main/patches/stable/linux-#{kver}-bore/0001-bore-cachy-patches.patch",
      "https://raw.githubusercontent.com/firelzrd/bore-scheduler/main/patches/bore-scheduler-latest.patch"
    ]

    dest = File.join(@dest_dir, "0010-bore-scheduler.patch")

    # Spróbuj każdego kandydata
    downloaded = candidates.any? do |url|
      try_download(url, dest)
    end

    unless downloaded
      @log.warn "Nie udało się pobrać BORE patch dla kernela #{kver}."
      @log.warn "Sprawdź https://github.com/firelzrd/bore-scheduler i dodaj patch ręcznie do patches/"
      return []
    end

    @log.info "BORE patch pobrany: #{File.basename(dest)}"
    [dest]
  end

  def bore_tag
    # Próbuj odgadnąć aktualny tag BORE — fallback do pustego
    ""
  rescue StandardError
    ""
  end

  # -------------------------------------------------------------------------
  # Valve VRAM patch set
  # Patche z drzewa Valve (SteamOS / gaming-kernel) priorytetyzują VRAM dla gier
  # Źródło: https://github.com/ValveSoftware/linux-gamescope-patches
  # lub bezpośrednio z SteamOS kernel tree
  # -------------------------------------------------------------------------
  def fetch_valve_vram
    @log.info "Pobieranie Valve VRAM patch set..."

    patches_fetched = []

    # Valve publikuje patche w kilku miejscach — próbujemy kolejno
    valve_patches = [
      {
        url:  "https://raw.githubusercontent.com/ValveSoftware/linux-gamescope-patches/main/patches/0001-drm-vram-mgr-prioritize-game-memory.patch",
        dest: "0020-valve-vram-priority.patch"
      },
      {
        url:  "https://raw.githubusercontent.com/ValveSoftware/linux-gamescope-patches/main/patches/0002-drm-avoid-vram-eviction-on-discrete-gpu.patch",
        dest: "0021-valve-vram-eviction.patch"
      }
    ]

    valve_patches.each do |p|
      dest_path = File.join(@dest_dir, p[:dest])
      if try_download(p[:url], dest_path)
        @log.info "  → #{p[:dest]}"
        patches_fetched << dest_path
      else
        @log.warn "  → Pominięto #{p[:dest]} (niedostępny)"
      end
    end

    if patches_fetched.empty?
      @log.warn "Valve VRAM patche niedostępne — włączone zostaną opcje CONFIG przez KernelConfigurator."
    end

    patches_fetched
  end

  # -------------------------------------------------------------------------
  # Helper: pobierz URL → plik; zwróć true jeśli sukces i plik ma >512B
  # -------------------------------------------------------------------------
  def try_download(url, dest)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    response = http.get(uri.request_uri)
    return false unless response.code.to_i == 200
    return false if response.body.to_s.length < 512  # puste / błąd HTML

    File.write(dest, response.body)
    true
  rescue StandardError => e
    @log.debug "  try_download #{url} → #{e.class}: #{e.message}"
    false
  end
end
