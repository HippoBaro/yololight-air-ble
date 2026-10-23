cask "yololight-air" do
  version "0.1.0"
  sha256 "24fad666ed01241d06b5e12afe7b97dda2b46bd93a852f8cc1144da4e4dbe4b2"

  url "https://github.com/HippoBaro/yololight-air-ble/releases/download/v#{version}/YoloLight-Air-#{version}-arm64.zip"
  name "YoloLight Air"
  desc "Control YoloLight Air lights from the menu bar"
  homepage "https://github.com/HippoBaro/yololight-air-ble"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "YoloLight Air.app"
end
