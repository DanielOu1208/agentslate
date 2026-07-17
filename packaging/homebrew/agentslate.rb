class Agentslate < Formula
  desc "Tailscale-only remote control bridge for Herdr"
  homepage "https://github.com/DanielOu1208/agentslate"
  url "https://github.com/DanielOu1208/agentslate/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "e65fcf1d965ca104a339332e9ffa4d1450ac6d4cdb5d0f54d832e29f505d6807"
  license "MIT"

  depends_on "rust" => :build
  depends_on :macos

  def install
    system "cargo", "install", *std_cargo_args
  end

  service do
    run [opt_bin/"agentslate", "serve"]
    keep_alive true
    environment_variables PATH: "#{Dir.home}/.local/bin:#{Dir.home}/.cargo/bin:#{std_service_path_env}"
    log_path var/"log/agentslate.log"
    error_log_path var/"log/agentslate.log"
  end

  test do
    assert_match "AgentSlate", shell_output("#{bin}/agentslate --help")
  end
end
