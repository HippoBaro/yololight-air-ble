cask "yololight-air" do
  version "0.1.1"
  sha256 "ae284d2a8affee42c72e962b65925e3cdb17ca0a8b2368ff343c44c11646cd19"

  url "https://github.com/HippoBaro/yololight-air-ble/releases/download/v#{version}/YoloLight-Air-#{version}-arm64.zip"
  name "YoloLight Air"
  desc "Control YoloLight Air lights from the menu bar"
  homepage "https://github.com/HippoBaro/yololight-air-ble"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "YoloLight Air.app"
end
