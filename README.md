# ATK Charge Animation — ATK mouse şarj animasyonu ve pil bildirimleri

[Türkçe](#türkçe) · [English](#english)

<p align="center">
  <img src="docs/demo-tr.gif" alt="Şarj animasyonu" width="368">
  <img src="docs/demo-en.gif" alt="Charging animation" width="368">
</p>

<p align="center">
  <img src="docs/notification-full.png" alt="Şarj tamamlandı bildirimi" width="380">
  <img src="docs/notification-low.png" alt="Düşük pil uyarısı" width="380">
</p>

---

## Türkçe

ATK mouse'unuzu USB-C kabloyla şarja taktığınızda ekranda şık bir şarj animasyonu gösteren, pil azalınca ve şarj dolunca da bildirim veren küçük bir Windows aracı. Pil yüzdesi **mouse'un kendisinden**, ATK HUB'ın kullandığı HID protokolüyle okunur.

### Özellikler

- **Şarj animasyonu:** Kablo takıldığı anda açılır, gerçek pil yüzdesini ve modelin adını gösterir. Mouse takıldıktan sonra değeri güncellerse animasyon da canlı olarak güncellenir (ATK HUB ile aynı değer).
- **Düşük pil uyarısı:** Kablosuz kullanırken pil **%20, %10 ve %5**'e düşünce sağ altta 5 saniyelik kırmızı uyarı balonu.
- **Şarj tamamlandı bildirimi:** Kabloda şarj olurken %100'e ulaşınca, seçtiğiniz temanın renginde bildirim.
- **Renk temaları:** Neon yeşil, Okyanus, Mor, Pembe, Gün batımı, Altın, Buz, Kırmızı ya da kendi iki renginiz.
- **Ayarlar penceresi:** Tema, bildirimler, dil; tek tıkla deneme. Değişiklikler anında uygulanır.
- Odağı çalmaz (oyun oynarken / yazarken klavyeniz kesilmez), tıklayınca kapanır.
- Türkçe / İngilizce.
- Kurulum gerektirmez: Windows'ta hazır gelen PowerShell 5.1 ve .NET ile çalışır, ATK HUB açıkken de çalışır.

<p align="center">
  <img src="docs/settings-tr.png" alt="Ayarlar penceresi" width="380">
  <img src="docs/theme-purple.png" alt="Mor tema" width="300">
</p>

### Kurulum

1. Bu repoyu indirin (**Code → Download ZIP**) ve bir klasöre çıkarın.
2. `test-et.bat` → animasyonu hemen bir kez gösterir (mouse takılıysa gerçek yüzdeyle).
3. `baslangica-ekle.bat` → arka planda başlatır ve Windows açılışına ekler.
4. `ayarlar.bat` → renk teması ve bildirim ayarları.

Kaldırmak için `kaldir.bat` çalıştırın, ardından klasörü silin.

> ZIP'ten çıkarılan dosyalar Windows tarafından engellenirse: dosyalara sağ tık → **Özellikler → Engellemeyi kaldır**.

### Desteklenen mouse'lar

ATK HUB'ın tanıdığı **251 ATK / VXE / MAD cihaz kimliği** (`cihazlar.csv`) tanınır:

| | Animasyon + model adı | Gerçek pil yüzdesi, düşük pil ve dolma bildirimleri |
|---|---|---|
| **COMPX ailesi** — X1, F1, A9, U2, Z1, Y9 (Ultimate, Extreme, Ultra, Pro Max…), VXE R1/R2/V3, MAD R… (144 mouse kimliği) | ✅ | ✅ |
| Diğer aileler (BITMOUSE, HOLTEK, HECHI, WAIZOWL) | ✅ | — (animasyon yüzdesiz gösterilir) |

Tamamen test edilen model: **ATK X1 Ultimate 2.0**. Başka bir modelde denediyseniz sonucu bir issue ile bildirin. Listede olmayan bir cihaz için `ogren.bat` ile kimliğini görebilirsiniz.

### Sorun giderme

Klasördeki `cihaz-log.txt` dosyasına bakın: açılışta `izleme basladi`, her takışta `takildi: ...` ve okunan pil değerleri (`pil: %70 sarj 4054 mV`) yazılır.

---

## English

A small Windows tool that shows a polished charging animation when you plug your ATK mouse into its USB-C cable, and notifies you when the battery runs low or is fully charged. The battery level is read **from the mouse itself**, using the same HID protocol as ATK HUB.

### Features

- **Charging animation:** appears the moment the cable is plugged in, with the real battery level and the model name; updates live if the mouse revises its value after plugging in (same value as ATK HUB).
- **Low battery warning:** a 5-second red notification at the bottom right when the battery drops to **20%, 10% and 5%** while wireless.
- **Fully charged notification:** when charging reaches 100%, in your theme's color.
- **Color themes:** Neon green, Ocean, Purple, Pink, Sunset, Gold, Ice, Red, or your own two colors.
- **Settings window:** theme, notifications, language and one-click previews; changes apply instantly.
- Never steals focus (safe while gaming or typing); click to dismiss.
- Turkish / English.
- Nothing to install: runs on the PowerShell 5.1 and .NET that ship with Windows; works alongside ATK HUB.

### Install

1. Download this repo (**Code → Download ZIP**) and extract it.
2. `test-et.bat` → shows the animation once (with the real level if the mouse is plugged in).
3. `baslangica-ekle.bat` → starts it in the background and adds it to Windows startup.
4. `ayarlar.bat` → color theme and notification settings.

To uninstall, run `kaldir.bat`, then delete the folder.

> If Windows blocks the extracted files: right-click them → **Properties → Unblock**.

### Supported mice

All **251 ATK / VXE / MAD device IDs** known to ATK HUB (`cihazlar.csv`) are recognized. The **COMPX family** (X1, F1, A9, U2, Z1, Y9 series, VXE R1/R2/V3, MAD R…, 144 mouse IDs) gets the real battery level plus low-battery and fully-charged notifications; other families (BITMOUSE, HOLTEK, HECHI, WAIZOWL) get the animation without a percentage. Fully tested on the **ATK X1 Ultimate 2.0** — please report other models in an issue. Use `ogren.bat` to find the ID of an unlisted device.

### Troubleshooting

Check `cihaz-log.txt` in the folder: `izleme basladi` on start, `takildi: ...` on every plug-in, and the battery readings (`pil: %70 sarj 4054 mV`).

---

## How it works / Nasıl çalışır

| | |
|---|---|
| Plug detection | `RegisterDeviceNotification` for `GUID_DEVINTERFACE_USB_DEVICE`, filtered to ATK vendor IDs (`373B`, `3554`) and looked up in `cihazlar.csv` |
| HID interface | Vendor-defined collection with 17-byte input/output reports (X1 Ultimate 2.0: interface `MI_01`, UsagePage `0xFF02`). ATK HUB matches the device by another collection (`0xFF04`); on Windows the report lives on a sibling collection. |
| Request | Output report `8`: `04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 49` — command `4` = *GetBatteryLevel* |
| Packet layout | `[command, status, address(2), length, data(10), checksum]`, checksum = `0x55 − (8 + sum of first 15 bytes)` |
| Response | Input report `8`, command `4`: `data[0]` = battery %, `data[1]` = charging (`1` = charging), `data[2..3]` = voltage in mV (big-endian). Responses carry the same checksum. |
| Low battery | While only a receiver is plugged in, the battery is queried through the receiver every 60 s |

Example response from a real mouse while charging: `08 04 00 00 00 02 41 01 0F 9F 00 00 00 00 00 00 57` → 65%, charging, 3999 mV.

| File | |
|---|---|
| `atk-sarj.ps1` | Background watcher, charging animation, notifications |
| `ayarlar.ps1`, `ayarlar.xaml` | Settings window (saved to `ayarlar.json`) |
| `AtkHid.cs` | HID battery reader and USB plug watcher (compiled at runtime by `Add-Type`) |
| `animasyon.xaml`, `bildirim.xaml` | WPF designs (theme colors filled in at runtime) |
| `metinler.json` | Turkish / English texts |
| `cihazlar.csv` | Supported devices; regenerate with `tools/extract-devices.js` from a local ATK HUB install |
| `tests/run-tests.ps1` | Test suite |

## Tests / Testler

```
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

79 tests: protocol (byte-exact request, checksum vs. ATK HUB's formula for all 256 commands, response parsing, rejection of unrelated reports), device table and Turkish-culture regressions, themes and settings (save/load, corrupt file, live reload), plug detection (simulated `WM_DEVICECHANGE`), low-battery thresholds (hysteresis, sleeping mouse), fully-charged logic, animation (levels 0/15/20/21/50/60/100, live 55%→65% update, unreadable battery, themes, English), notifications (text, position, focus, click-to-close), the settings window (driven programmatically), real hardware (10 consecutive reads, consistency, response checksums, plausible voltage) and single-instance. Use `-SkipHardware` without the mouse and `-SkipUI` to avoid windows popping up. Tests use temporary settings/log files and never touch yours.

## Disclaimer / Yasal not

This is an unofficial, community project. It is not affiliated with, endorsed by or supported by ATK, VXE or MAD. Product names are trademarks of their respective owners. The battery protocol was documented by examining how the ATK HUB application talks to the mouse, for interoperability; no ATK code or assets are included. It only sends a read-only battery query and never changes mouse settings. Use at your own risk.

Bu resmi olmayan bir topluluk projesidir; ATK, VXE veya MAD ile bir bağı yoktur. Mouse'a yalnızca pil seviyesini soran, salt okunur bir komut gönderir; mouse ayarlarını değiştirmez.

## License / Lisans

Copyright (c) 2026 salihjrx. Licensed under the [PolyForm Strict License 1.0.0](LICENSE).

You may download and use this software for any noncommercial purpose. You may **not** distribute it, publish modified versions, or build new works based on it. Source is visible for transparency; this is not an open-source license.

Bu yazılımı ticari olmayan her amaçla indirip kullanabilirsiniz. Yazılımı **dağıtamaz, değiştirilmiş sürümünü yayınlayamaz ve üzerine yeni bir proje kuramazsınız.** Kaynak kod şeffaflık için görünürdür; bu bir açık kaynak lisansı değildir.
