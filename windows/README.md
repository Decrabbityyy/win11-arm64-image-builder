# windows/ — DISM 離線版（x64 Windows）

在 **x64 Windows** 上把 **Win11 ARM64 ISO + 驅動** 直接做成**可開機、已含驅動的 qcow2**，
**不跑 Setup、不開 qemu**。靠 DISM 套用映像 + 離線注入驅動 + bcdboot。

## 為什麼用這個（vs macos/ 的 qemu 流程）
| | windows/（DISM 離線） | macos/（qemu 跑 Setup） |
|---|---|---|
| 驅動簽章提示 | **完全沒有**（離線注入不經互動 PnP） | 需 CA:FALSE 憑證 + 匯入 TrustedPublisher |
| 時間 | ~5–10 分（無裝機 reboot） | ~30 分 |
| boot-press / 點擊器 | 不需要 | 需要 |
| 環境 | **要 x64 Windows** | Mac / 任何能跑 qemu |

> 離線 `DISM /Add-Driver` 不會跳「Windows can't verify the publisher」——那是互動式 PnP 才有的。
> 自簽驅動要能在開機時**載入**仍需 BCD `testsigning on`（腳本第 7 步直接設）。

## 需求
- **x64 Windows，系統管理員**（diskpart / dism / bcdboot 內建）
- **qemu-img**（QEMU for Windows，需加入 PATH）——最後 VHDX→qcow2 轉檔用
- Win11 ARM64 ISO（IoT Enterprise LTSC，index 2）

## 用法
```powershell
# 1) 設定（PowerShell 原生：build.ps1 會 dot-source windows\config.ps1）
copy windows\build_from_zip.ps1 windows\build_from_zip.ps1   # 編輯 $SRC_ISO（必填）、$DRIVERS_DIR（預設抓 dev release）

# 2) 執行（會自動提權到系統管理員）
powershell -ExecutionPolicy Bypass -File windows\build_from_zip.ps1
#   -> win11-droidvm-final.qcow2
```

## 流程（build.ps1）
1. 解析驅動來源（URL→下載 dev release zip / 本地 zip / 資料夾）
2. 掛載 ISO 取 `install.wim`
3. 建 + 掛 VHDX，GPT 分割 ESP(FAT32)+MSR+Windows(NTFS)
4. `dism /Apply-Image` 套用映像
5. `dism /Add-Driver /Recurse /ForceUnsigned` **離線注入驅動**
6. 離線移除多餘 provisioned Appx（debloat）
7. `bcdboot` 做開機檔，`bcdedit /store` 開 testsigning + nointegritychecks
8. 放入 `unattend.xml`（首次開機 OOBE 建 USER、autologon）
9. 卸載 VHDX → `qemu-img convert` 成 qcow2

