# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Tworzy GitHub Release i uploaduje pliki .rpm jako assety.
# Używa GitHub REST API v3.
class GithubReleaser
  class Error < StandardError; end

  API_BASE    = "https://api.github.com"
  UPLOAD_BASE = "https://uploads.github.com"

  def initialize(cfg, log)
    @cfg   = cfg
    @log   = log
    @token = cfg.github_token  # zgłosi błąd jeśli brak
  end

  # Tworzy release i uploaduje assety; zwraca URL release'u
  def release(rpm_files)
    tag     = "v#{@cfg.kernel_version}"
    release = find_or_create_release(tag)
    upload_assets(release, rpm_files)
    release["html_url"]
  end

  private

  # -------------------------------------------------------------------------
  # Release
  # -------------------------------------------------------------------------
  def find_or_create_release(tag)
    existing = get_release_by_tag(tag)
    if existing
      @log.info "Release #{tag} już istnieje: #{existing['html_url']}"
      return existing
    end

    @log.info "Tworzenie nowego release #{tag}..."
    body = {
      tag_name:         tag,
      target_commitish: "main",
      name:             "LegendaryOS Kernel #{@cfg.kernel_version}",
      body:             release_body,
      draft:            false,
      prerelease:       false
    }

    resp = api_post("/repos/#{@cfg.github_owner}/#{@cfg.github_repo}/releases", body)
    raise Error, "Tworzenie release nieudane: #{resp['message']}" if resp["message"]

    @log.info "Release utworzony: #{resp['html_url']}"
    resp
  end

  def get_release_by_tag(tag)
    resp = api_get("/repos/#{@cfg.github_owner}/#{@cfg.github_repo}/releases/tags/#{tag}")
    resp["id"] ? resp : nil
  rescue Error
    nil
  end

  def release_body
    <<~MD
      ## LegendaryOS Kernel #{@cfg.kernel_version}#{@cfg.localversion}

      Jądro zoptymalizowane pod sterowniki **NVIDIA akmod** dla dystrybucji LegendaryOS (Fedora-based).

      ### Zmiany / optymalizacje
      - Kompilacja z **-O3**
      - Scheduler: **HZ=1000**, **PREEMPT** (desktop)
      - Podpisywanie modułów **wyłączone** (akmod kompatybilność)
      - `CONFIG_KALLSYMS_ALL=y`, `CONFIG_DMABUF_HEAPS=y`
      - **Nouveau wyłączony** — używaj `akmod-nvidia`
      - `CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y`

      ### Instalacja
      ```bash
      sudo dnf install legendaryos-kernel-#{@cfg.kernel_version}-#{@cfg.release_tag}.#{@cfg.arch}.rpm
      sudo reboot
      ```

      ### Architektura
      #{@cfg.arch}
    MD
  end

  # -------------------------------------------------------------------------
  # Upload assetów
  # -------------------------------------------------------------------------
  def upload_assets(release, files)
    upload_url_template = release["upload_url"]
    # Template ma postać: https://uploads.github.com/repos/.../releases/ID/assets{?name,label}
    upload_url_base = upload_url_template.sub(/\{.*\}$/, "")

    files.each do |file|
      filename = File.basename(file)
      @log.info "Uploadowanie: #{filename} (#{human_size(File.size(file))})"

      uri = URI("#{upload_url_base}?name=#{URI.encode_www_form_component(filename)}")
      upload_file(uri, file)

      @log.info "  → upload OK: #{filename}"
    end
  end

  def upload_file(uri, path)
    data = File.binread(path)

    http          = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl  = true
    http.read_timeout = 300  # duże pliki

    request = Net::HTTP::Post.new(uri)
    request["Authorization"]  = "Bearer #{@token}"
    request["Content-Type"]   = "application/octet-stream"
    request["Accept"]         = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request.body = data

    response = http.request(request)
    parsed   = JSON.parse(response.body)

    raise Error, "Upload nieudany (#{response.code}): #{parsed['message']}" unless response.code.to_i == 201

    parsed
  end

  # -------------------------------------------------------------------------
  # HTTP helpers
  # -------------------------------------------------------------------------
  def api_get(path)
    uri      = URI("#{API_BASE}#{path}")
    http     = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Get.new(uri)
    set_headers(req)

    resp = http.request(req)
    JSON.parse(resp.body)
  end

  def api_post(path, body)
    uri      = URI("#{API_BASE}#{path}")
    http     = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Post.new(uri)
    set_headers(req)
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)

    resp = http.request(req)
    JSON.parse(resp.body)
  end

  def set_headers(req)
    req["Authorization"]         = "Bearer #{@token}"
    req["Accept"]                = "application/vnd.github+json"
    req["X-GitHub-Api-Version"]  = "2022-11-28"
    req["User-Agent"]            = "LegendaryOS-KernelBuilder/1.0"
  end

  def human_size(bytes)
    units = %w[B KB MB GB]
    idx   = 0
    size  = bytes.to_f
    while size >= 1024 && idx < units.length - 1
      size /= 1024
      idx  += 1
    end
    format("%.1f %s", size, units[idx])
  end
end
