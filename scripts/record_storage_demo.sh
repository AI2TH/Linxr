#!/bin/bash
# Automate recording the MANAGE_EXTERNAL_STORAGE demo video for Google Play Store.
# Make sure your phone is connected and authorized via ADB.

echo "=== Waking up screen and launching app ==="
adb shell input keyevent 224
adb shell input swipe 500 2000 500 500
adb shell monkey -p com.ai2th.linxr -c android.intent.category.LAUNCHER 1
sleep 2

echo "=== Starting screen recording ==="
adb shell screenrecord --time-limit 15 /sdcard/manage_storage.mp4 &
sleep 1

echo "=== Navigating UI ==="
adb shell input tap 972 2113   # Taps Settings Tab
sleep 2
adb shell input swipe 500 1500 500 500  # Scrolls down to Shared Folder card
sleep 2
adb shell input tap 512 939    # Taps 'Documents' quick pick option
sleep 2
adb shell input tap 376 1204   # Taps 'Open System File Manager'
sleep 4

echo "=== Pulling video ==="
adb pull /sdcard/manage_storage.mp4 ./build/linxr_all_files_access.mp4
echo "=== Done! Video saved to build/linxr_all_files_access.mp4 ==="
