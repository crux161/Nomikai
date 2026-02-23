#!/bin/zsh

# build/ios/iphoneos/Runner.app
set -e

cd build/ios/iphoneos
rm -rf Payload/
mkdir Payload
cp -rv Runner.app Payload/
zip -qr Nomikai.ipa Payload/
#open /Applications/Sideloadly.app
