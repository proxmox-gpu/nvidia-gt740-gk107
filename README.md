# nvidia-gt740-gk107

Проброс **NVIDIA GeForce GT 740 (GK107)** в ВМ Windows Server на чистом **Proxmox VE 9.2 (Debian 13)** — пошагово, готовыми bash-скриптами. Результат: ВМ на OVMF/q35 владеет картой целиком, RDP-сессии рисуются на GPU и кодируются в H.264 на NVENC карты.

> ⚠️ **Статус.** На **GT 740 (GK107)** и **Windows Server 2025** этот runbook ещё не прогонялся. Server 2025 + драйвер 475.14 — эксперимент: если не взлетит — та же процедура на Server 2022 (скрипты не меняются).

## Как это устроено

- Всё выполняется **на хосте PVE от root**, скриптами из этого репозитория. Репозиторий попадает на хост через `git`.
- Внутрь Windows — **только через QEMU Guest Agent** (`qm guest exec`, `agent/file-write`), скрипты делают это сами. Пароль администратора Windows не нужен: агент работает от SYSTEM.
- Единственный ручной шаг — установка Windows в консоли noVNC.
- Каждый скрипт печатает `[PASS]`/`[FAIL]`, итог `RESULT: PASS|FAIL`, подсказку следующего шага и пишет полный лог в `logs/<скрипт>-<время>.log` (в git не попадает). Если что-то пошло не так — пришлите этот лог на разбор.
- Вывод из Windows в консоли хоста всегда читаемый, в том числе кириллица: CP866/UTF-8 перекодируются автоматически (см. [Кодировка вывода](#кодировка-вывода-гостя)).

## Требования

| Что | Зачем / как проверить |
| --- | --- |
| CPU и плата с **VT-x + VT-d** (Intel) или **AMD-V + IOMMU** (AMD), включены в BIOS | `host/01-preflight.sh` |
| Консоль хоста — **на встроенной графике**, не на GT 740 | после передачи карты vfio-pci консоль на ней пропадёт (веб-интерфейс работает) |
| Карта в слоте, где её IOMMU-группа не делит устройства с чужими | `host/04-verify-host.sh` |
| Proxmox VE 9.x, свежая установка | `pveversion` |

**Ограничения:** карта отдаётся одной ВМ; ВМ с картой не мигрирует вживую; снапшоты — только без RAM. У Kepler нет FLR, поэтому при каждом старте ВМ `failed to reset PCI device …, but trying to continue` — **это норма**.

**Закреплённые версии** (в `.env.example`):

| Компонент | Версия | Проверка |
| --- | --- | --- |
| virtio-win | **0.1.271** (`archive-virtio/virtio-win-0.1.271-1`) | SHA256: при первом скачивании скрипт печатает хеш → сверить → вписать в `VIRTIO_SHA256` |
| Драйвер NVIDIA | **475.14** Standard, Win10/11 x64 (R470, последняя ветка для Kepler) | SHA256 `d1e8401f…6dbd9bac2e` зашит, проверяется всегда |

## Подготовка на хосте

Подключиться к хосту по ssh, от root:

```bash
cd /root
git clone git@github.com:proxmox-gpu/nvidia-gt740-gk107.git     # или https-URL
cd nvidia-gt740-gk107
git checkout feature/gt740-runbook
cp .env.example .env
nano .env          # параметры с комментариями внутри файла
```

Перед каждым сеансом работ — `git pull`.

## Шаги

| # | Скрипт | Где | Перезагрузка | Время |
| --- | --- | --- | --- | --- |
| 1 | `host/01-preflight.sh` | хост | — | 1 мин |
| 2 | `host/02-iommu.sh` | хост | (общая с шагом 3) | 1 мин |
| 3 | `host/03-vfio.sh` → `host/03-vfio-check.sh` → `reboot` | хост | **хост, 1 раз** | 5 мин |
| 4 | `host/04-verify-host.sh` | хост | — | 1 мин |
| 5 | `host/05-mapping.sh` | хост | — | 1 мин |
| 6 | `host/06-create-vm.sh` | хост | — | 2 мин |
| — | **Установка Windows вручную** | noVNC | — | ~20 мин |
| 7 | `host/07-guest-baseline.sh` | хост → гость | — | 2 мин |
| 8 | `host/08-attach-gpu.sh` | хост → гость | ВМ | 3 мин |
| 9 | `host/09-driver-iso.sh` | хост | — | 2 мин |
| 10 | `host/10-install-driver.sh` | хост → гость | ВМ (в конце) | ~8 мин |
| 11 | `host/11-verify-gpu.sh` | хост → гость | — | ~7 мин |
| 12 | `host/12-finalize.sh` (после RDP-теста) | хост → гость | — | 1 мин |

Запуск всегда из корня репозитория: `./host/NN-имя.sh`. Вопросы `[y/N]` можно пропустить: `ASSUME_YES=1 ./host/…`.

---

### 1. Инвентаризация

```bash
./host/01-preflight.sh
```

Проверяет версию PVE, VT-x/AMD-V, находит карту NVIDIA, её функции (видео + HDMI-аудио), состояние IOMMU и interrupt remapping, ставит недостающие пакеты (`genisoimage`, `python3`, `curl`, `pciutils`). Пишет в `.env` `GPU=` и `IDS=`.

Ожидаемо для GT 740 (адрес у вас свой):

```
    01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GK107 [GeForce GT 740] [10de:0fc8] (rev a1)  driver=nouveau
    01:00.1 Audio device [0403]: NVIDIA Corporation GK107 HDMI Audio Controller [10de:0e1b] (rev a1)  driver=snd_hda_intel
[PASS] GK107 GeForce GT 740 (10de:0fc8)
[PASS] host console is not on the NVIDIA card (boot_vga=0)
```

- `[WARN] … BOOT VGA` — карта основная для консоли хоста. Переключите в BIOS основной видеовыход на встроенную графику; иначе после шага 3 локальная консоль погаснет.
- Несколько карт NVIDIA — впишите нужную в `GPU=` (адрес без `.0`) и перезапустите.

### 2. IOMMU

```bash
./host/02-iommu.sh
```

Ядро PVE включает Intel IOMMU по умолчанию, AMD-Vi включён всегда — обычно скрипт пишет `IOMMU already active - nothing to change`. Только если `/sys/class/iommu` пуст на Intel, добавляет `intel_iommu=on` туда, где загрузчик реально берёт параметры: `/etc/kernel/cmdline` + `proxmox-boot-tool refresh` (ZFS/systemd-boot) или `GRUB_CMDLINE_LINUX_DEFAULT` + `update-grub`. Существующие параметры сохраняются, бэкап рядом (`*.bak-<время>`).

> Проверку `dmesg | grep 'DMAR: IOMMU enabled'` из старых гайдов не используем: при включении «по умолчанию» строки нет, проверка даёт ложное «выключено».

### 3. vfio-pci

```bash
./host/03-vfio.sh
./host/03-vfio-check.sh
reboot
```

Файлы **не перезаписываются**: недостающие строки дописываются в конец, уже имеющиеся не трогаются; перед изменением — бэкап `<файл>.bak-<время>`. Если в `/etc/modprobe.d/` уже есть другой `options vfio-pci ids=` — скрипт ничего не меняет и останавливается: строки нужно свести вручную (один список `ids=` на хост). Затем пересобирается initramfs всех ядер.

Дописываемые строки:

| Файл | Содержимое |
| --- | --- |
| `/etc/modprobe.d/vfio.conf` | `options vfio-pci ids=<IDS>` + `softdep nouveau/nvidiafb/snd_hda_intel pre: vfio-pci` — vfio-pci забирает карту раньше штатных драйверов |
| `/etc/modprobe.d/blacklist-gpu.conf` | `blacklist nouveau`, `blacklist nvidiafb` |
| `/etc/modules-load.d/vfio.conf` | `vfio`, `vfio_iommu_type1`, `vfio_pci` (`vfio_virqfd` в ядрах 6.2+ нет) |

`03-vfio-check.sh` — проверка без изменений, перезагружать хост только при `RESULT: PASS`:

- `IDS` в `.env` совпадают с реальными функциями карты;
- в трёх файлах есть все нужные строки (ids, softdep, blacklist, модули);
- итоговая конфигурация modprobe (`modprobe -c`) и конфликты: другие файлы с `vfio-pci ids=`, `vfio_virqfd`, blacklist vfio;
- в **каждом** initramfs есть файлы конфигурации и он пересобран после их изменения;
- в параметрах следующей загрузки включён IOMMU (если он ещё не активен);
- текущая привязка драйверов: до перезагрузки — `nouveau`/`snd_hda_intel` (норма), после — `vfio-pci`.

Это **единственная перезагрузка хоста**.

### 4. Проверка хоста

```bash
./host/04-verify-host.sh
```

Критерий: `IOMMU active`, `only functions of the card in its IOMMU group`, обе функции `-> vfio-pci`.

- В группе чужие устройства → переставить карту в другой слот. `pcie_acs_override` **не использовать**: ломает изоляцию ВМ от хоста.
- Функция не на `vfio-pci` → проверить `IDS` в `.env`, повторить шаг 3.

### 5. Resource mapping

```bash
./host/05-mapping.sh
```

Создаёт (или обновляет) `Datacenter → Resource Mappings → PCI` с именем `MAP` (`gt740`). Путь без номера функции → в ВМ уходят обе функции. ВМ ссылается на имя, а PVE при каждом старте проверяет vendor/device/subsystem/IOMMU-группу.

```
gt740
	map id=10de:0fc8,iommugroup=…,node=…,path=0000:01:00,subsystem-id=…
```

### 6. Создание ВМ

```bash
./host/06-create-vm.sh
```

Скачивает `virtio-win-0.1.271.iso` (если его ещё нет), печатает SHA256, проверяет наличие драйвера `vioscsi\2k25`, создаёт ВМ:

| Параметр | Зачем |
| --- | --- |
| `--machine q35` | обязательно: карта в PCIe-порту (`pcie=1`). На i440fx драйвер падает в Code 43 |
| `--bios ovmf` + `efidisk0 … pre-enrolled-keys=1` | UEFI + Secure Boot (ключи MS 2023) |
| `--cpu host`, `--balloon 0` | память ВМ с пробросом закрепляется целиком |
| `virtio-scsi-single` + `iothread=1,discard=on` | рекомендация PVE для Windows |
| `--vga virtio` | страховочная консоль noVNC — **оставить**, карта будет вторым адаптером |
| `--agent enabled=1` | через агента идут все дальнейшие шаги |

Не добавлять: `viommu=…` в `machine` (ВМ с картой не стартует), `hidden=1`, `x-vga=1`, `romfile` — на Kepler с драйвером ≥ 465 не нужны.

### Установка Windows (вручную, noVNC)

PVE GUI → ВМ → **Console**:

1. **Start**, сразу нажать любую клавишу на «Press any key to boot from CD or DVD…» (≈5 с; не успели — Reset).
2. Windows Server 2025 → **Desktop Experience** → Custom. Список дисков пуст: **Load driver** → CD `virtio-win` → `vioscsi\2k25\amd64` (если скрипт 6 сказал, что `2k25` нет, — `vioscsi\2k22\amd64`).
3. Задать пароль Administrator, войти.
4. С CD `virtio-win` запустить **`virtio-win-guest-tools.exe`** — драйверы virtio (сеть, дисплей, balloon) и **QEMU Guest Agent**.
5. Если в сети нет DHCP — задать IP в консоли (Server Manager → Local Server → Ethernet).

RDP включать руками не нужно — это сделает шаг 7.

> Server 2022 вместо 2025: другой ISO в `WIN_ISO`, драйвер `vioscsi\2k22\amd64`. Остальное без изменений.

### 7. Базовая настройка гостя

```bash
./host/07-guest-baseline.sh
```

Ждёт агента, показывает ОС/сеть/устройства с проблемами, включает RDP (правила firewall по имени `RemoteDesktop-UserMode-In-TCP/UDP` — не зависит от языка Windows), `TermService` → Automatic, `CrashDumpEnabled=3` (малый дамп — быстрая перезагрузка при отладке), проверяет порт 3389 с хоста, делает снапшот **`clean-os`**.

Критерий: `RDP enabled and listening on 3389`, `TCP <IP>:3389 reachable`. Зайдите по RDP один раз руками.

### 8. Подключение карты

```bash
./host/08-attach-gpu.sh
```

- проверяет, что ВМ — q35 без vIOMMU и что карту не держит другая **запущенная** ВМ;
- если в госте уже стоит драйвер NVIDIA — отключает его на одну загрузку (`nvlddmkm Start=4`), иначе он стартует без MSI → цикл BSOD;
- `qm shutdown` → `hostpci0: mapping=gt740,pcie=1` → `qm start`;
- показывает функции NVIDIA в госте.

Ожидаемо на старте ВМ (норма, у Kepler нет FLR):

```
failed to reset PCI device '0000:01:00.0', but trying to continue as not all devices need a reset
```

В госте до драйвера: видео — `Microsoft Basic Display Adapter`, `Error`, `CM_PROB_FAILED_ADD` (код 31) — **норма**. `InstanceId` попадает в лог.

### 9. ISO с драйвером

```bash
./host/09-driver-iso.sh
```

Качает `475.14-desktop-win10-win11-64bit-international-whql.exe` **на хосте**, сверяет SHA256 с закреплённым, собирает `local:iso/nvidia-475.14.iso` (метка `NV47514`) и вставляет в CD-привод ВМ на лету. Быстрее и не зависит от сети гостя.

`NV_INSTALL_MODE=driver-only` — дополнительно распаковывает пакет (`7z`) для установки только `Display.Driver` (без GeForce Experience/ShadowPlay) — вариант для терминального сервера.

### 10. Установка драйвера

```bash
./host/10-install-driver.sh
```

Порядок — главное во всём runbook:

1. снапшот **`pre-driver`**;
2. копия установщика с ISO, SHA256 + подпись Authenticode. Если подпись `UnknownError` из-за отсутствующего корня метки времени **Entrust.net (2048)** (`TRUST_E_TIME_STAMP`, вероятно на новых сборках Windows) — скрипт сам качает корень с `ctldl.windowsupdate.com`, сверяет SHA1 `503006…3431` и добавляет в `LocalMachine\Root`;
3. ключи MSI создаются заранее, установщик запускается **в фоне** (`-s -noreboot`), хост опрашивает код возврата раз в 30 с (0 и 1 — успех);
4. **MSI повторно на обе функции** (установщик может удалить ключ), политики RDP, `nvlddmkm Start=3`;
5. только теперь — перезагрузка ВМ (с подтверждением).

> ⛔ Если скрипт пишет `MSI/policies are NOT confirmed - do NOT reboot` — **не перезагружайте гостя**. Без MSI драйвер Kepler в ВМ работает на INTx, и Windows через 15–30 с после загрузки падает в `0x116 VIDEO_TDR_FAILURE` — бесконечно.

Если во время установки агент пропал — гость упал: `./host/rescue-bsod-loop.sh` или откат `qm stop <VMID> && qm rollback <VMID> pre-driver`.

### 11. Проверка

```bash
./host/11-verify-gpu.sh
```

Критерии (все `[PASS]`):

- обе функции `OK`, `MSISupported: 1`, IRQ вида `4294967xxx(MSI)` (отрицательный номер = MSI; `16(INTx)` — MSI не включился → `host/fix-msi.sh`);
- `nvidia-smi : NVIDIA GeForce GT 740, 475.14, …, WDDM`;
- нет BugCheck за 30 минут, `nvlddmkm Start=3`, три политики RDP = 1;
- 5 минут наблюдения: агент отвечает всё время, сбросов карты (`vfio-pci …: resetting`) нет — гость не перезагружается сам.

При успехе возвращает `CrashDumpEnabled=7`. Длительность наблюдения: `WATCH_SECONDS=600 ./host/11-verify-gpu.sh`.

### 12. RDP-ускорение и финал

1. Откройте **новое** RDP-подключение (политики действуют на новые сессии).
2. Запустите видео (YouTube в Edge) → Диспетчер задач → Производительность → **GPU — NVIDIA GeForce GT 740** показывает загрузку.
3. ```bash
   ./host/12-finalize.sh
   ```
   Ищет событие RdpCoreTS **170** `AVC hardware encoder enabled: 1, encoder name is NVIDIA H.264 Encoder MFT`, делает снапшот **`gpu-ok`**, извлекает ISO драйвера.

Эксплуатация: перезагрузки гостя и `qm shutdown`/`qm start` безопасны; снапшоты — без RAM. После **любого** обновления драйвера NVIDIA или смены слота/чипсета — `./host/fix-msi.sh` до перезагрузки.

---

## Вспомогательные скрипты

| Скрипт | Когда |
| --- | --- |
| `host/gpu-status.sh` | быстрый статус: драйвер на хосте, конфиг ВМ, журнал ядра по карте, функции NVIDIA в госте |
| `host/diag-gpu.sh [--rom]` | карта видна в госте, но не стартует (код 43/10/31): сверка конфига ВМ с runbook, способы сброса, BAR/ROM/MSI, IOMMU-группа, interrupt remapping, журнал ядра; в госте — код и статус проблемы, пакет драйвера, события `nvlddmkm`/Kernel-PnP, `setupapi.dev.log`. Ничего не меняет. `--rom` (ВМ остановлена) — снимает ROM карты в `logs/` и проверяет наличие UEFI GOP |
| `host/dump-vbios.sh` | полный VBIOS карты через `nvflash64 --save` в госте (только чтение, карта не прошивается), когда `diag-gpu.sh --rom` даёт обрезанный образ. Zip «NVFlash for Windows» положить в `tools/nvflash.zip` (`NVFLASH_ZIP`), хеш закрепить в `NVFLASH_SHA256`. Результат — `logs/vbios-nvflash-*.rom` с проверкой целостности и UEFI GOP |
| `lib/rom_check.py FILE` | проверить любой дамп ROM: цепочка образов, контрольные суммы, UEFI GOP, версия VBIOS |
| `host/gx-test.sh` | проверить, что вывод гостя (кириллица) читается в консоли хоста |
| `host/rescue-bsod-loop.sh` | гость в цикле BSOD: ловит окно агента и отключает драйвер (`nvlddmkm Start=4`) |
| `host/fix-msi.sh` | MSI + политики RDP + `Start=3` + перезагрузка (после rescue, обновления драйвера, смены слота) |
| `host/rollback.sh` | откат: снять карту с ВМ / вернуть карту хосту / удалить маппинг — по вопросам |

## Кодировка вывода гостя

Русская Windows отдаёт вывод `cmd`, `reg`, `pnputil`, `certutil` через агента в **CP866**, а PVE кладёт байты в JSON как latin-1 — без обработки в консоли «кракозябры». Поэтому все вызовы в гостя идут только через функцию `gx` (`lib/common.sh`) и декодер `lib/gx_decode.py`:

- байты восстанавливаются из latin-1 и декодируются **построчно**: сначала строго UTF-8, при ошибке — CP866;
- PowerShell-скрипты из `guest/` переключают вывод на UTF-8, нативные утилиты остаются в CP866 — оба варианта в одном потоке читаются корректно;
- логи в `logs/` — в UTF-8;
- если автоопределение ошиблось — `GUEST_ENCODING=cp866` (или `utf-8`) в `.env`.

Проверка: `./host/gx-test.sh` — должны читаться `Том в устройстве C …`, имя группы `Администраторы` и т. п.

Скрипты в `guest/*.ps1` — **только ASCII**: `agent/file-write` не принимает другие символы (`Wide character in subroutine entry`).

## Troubleshooting

| Симптом | Причина | Что делать |
| --- | --- | --- |
| После установки драйвера гость перезагружается каждые 1–2 мин, агент живёт 15–30 с, в `journalctl -k` на каждый круг `vfio-pci …: resetting` | MSI не включён / удалён установщиком | `./host/rescue-bsod-loop.sh` → дождаться стабильной загрузки → `./host/fix-msi.sh` → `./host/11-verify-gpu.sh` |
| `failed to reset PCI device …, but trying to continue` | у Kepler нет FLR | норма |
| `warning: VFIO dma-buf not supported in kernel …` | QEMU 11 + текущее ядро | безвредно |
| `vfio …: group N used in multiple address spaces`, ВМ не стартует | `viommu=…` в `machine` | `qm set <VMID> -machine q35` без `viommu` |
| `PCI device mapping not found for '<имя>'` | опечатка в имени маппинга | сверить `MAP` и `/etc/pve/mapping/pci.cfg` |
| ВМ не стартует: устройство занято | карту держит другая запущенная ВМ | остановить её или убрать её `hostpci` |
| Видео `Error`, код 43 (`CM_PROB_FAILED_POST_START`), IRQ `INTx` | ВМ на i440fx (нет PCIe) | перевести на q35 + `pcie=1`, затем `fix-msi.sh` (новый InstanceId) |
| Видео `Error`, код 43 (`CM_PROB_FAILED_POST_START`) на q35 + `pcie=1` | грязное состояние карты (нет способа сброса), отличия ВМ от runbook (`cpu`), нет UEFI GOP в ROM | `./host/diag-gpu.sh`, при остановленной ВМ — `./host/diag-gpu.sh --rom`; грязная карта — выключить хост по питанию и `qm start` |
| `diag-gpu.sh --rom`: `ROM dump is TRUNCATED`, в журнале ядра `Invalid PCI ROM header signature … got 0xffff` | ROM BAR карты читается не полностью; гость получает тот же обрезанный образ | `./host/dump-vbios.sh` → при `COMPLETE` подключить через `romfile=` (см. вывод скрипта); для пробы — `rombar=0` |
| Видео — код 31 `Microsoft Basic Display Adapter` | драйвер ещё не стоит | шаг 9–10 |
| `NVIDIA GeForce GT 740`, код 14 `CM_PROB_NEED_RESTART` | драйвер ждёт перезагрузки | шаг 10 (MSI) → перезагрузка |
| Установщик: `-2146869243` / подпись `UnknownError` | нет корня Entrust.net (2048) | шаг 10 делает это сам; вручную — повторить шаг 10 |
| Установщик на Server 2025 отказывается ставиться / BSOD при загрузке при корректном MSI | Server 2025 не поддерживается веткой R470 | откат на `clean-os`/пересоздание ВМ на **Server 2022** |
| `lspci -nnk` после перезагрузки хоста — `nouveau`, не `vfio-pci` | initramfs не обновлён / неверные `IDS` | проверить `IDS`, повторить шаг 3 и перезагрузку |
| Агент не отвечает | не установлен `virtio-win-guest-tools.exe` / служба `QEMU-GA` остановлена | установить из CD virtio-win, проверить `qm config <VMID> \| grep agent` |
| В консоли хоста «кракозябры» | автоопределение кодировки | `GUEST_ENCODING=cp866` в `.env`, `./host/gx-test.sh` |
| `nvidia-smi` не найден | Standard-драйвер кладёт его только в DriverStore | скрипты ищут сами; вручную — `C:\Windows\System32\DriverStore\FileRepository\nv_*\nvidia-smi.exe` |
| `utilization.gpu: [N/A]` | GK107 не отдаёт загрузку через nvidia-smi | смотреть Диспетчер задач / счётчики `GPU Engine` |

Код ошибки BSOD в госте: `C:\Windows\Minidump\*.dmp`, событие System 1001 (`The bugcheck was: 0x00000116 …`).

## Откат

```bash
./host/rollback.sh
```

По шагам и с вопросами: (1) снять карту с ВМ — драйвер и MSI в госте сохраняются, обратно — `./host/08-attach-gpu.sh`; (2) вернуть карту хосту — удалить только строки, добавленные шагом 3 (остальное содержимое файлов сохраняется; опустевший файл удаляется), пересобрать initramfs, перезагрузить хост; (3) удалить маппинг. Откат ВМ на снапшот: `qm shutdown <VMID> && qm rollback <VMID> clean-os|pre-driver|gpu-ok`.

## Структура репозитория

```
.env.example         параметры хоста/ВМ и закреплённые версии (копия -> .env, в git не попадает)
lib/common.sh        общие функции: логи, PASS/FAIL, ожидание агента, gx, guest_ps, снапшоты
lib/gx_decode.py     декодер вывода гостя (CP866/UTF-8 -> UTF-8)
lib/rom_check.py     проверка дампа ROM/VBIOS (образы, контрольные суммы, UEFI GOP)
host/NN-*.sh         шаги 1-12, запускаются на хосте по порядку
host/*.sh            вспомогательные: gpu-status, diag-gpu, dump-vbios, gx-test, rescue-bsod-loop, fix-msi, rollback
guest/*.ps1          PowerShell для гостя (ASCII), копируются и запускаются через агента
logs/                логи запусков (в git не попадают)
tools/               сторонние утилиты, например nvflash.zip (в git не попадают)
```

## Ссылки

- [Proxmox VE Wiki — PCI(e) Passthrough](https://pve.proxmox.com/wiki/PCI(e)_Passthrough) — IOMMU, vfio-pci `ids`, `softdep`, blacklist, требования q35/OVMF
- [Proxmox VE Admin Guide — Editing the Kernel Command Line](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#sysboot_edit_kernel_cmdline) — GRUB vs `proxmox-boot-tool`
- [Proxmox VE Admin Guide — Resource Mapping](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#resource_mapping)
- [Proxmox VE Wiki — Windows 2022 guest best practices](https://pve.proxmox.com/wiki/Windows_2022_guest_best_practices), [Windows VirtIO Drivers](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers)
- [virtio-win archive 0.1.271](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/)
- [NVIDIA Driver Downloads](https://www.nvidia.com/Download/index.aspx) — GeForce 700 Series → GeForce GT 740 → Windows 10 64-bit
- [Microsoft — Remote Desktop Session Host: Remote Session Environment policies](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-terminalserver) — `bEnumerateHWBeforeSW`, `AVC444ModePreferred`, `AVCHardwareEncodePreferred`
- [Microsoft — Line-Based vs. Message Signaled-Based Interrupts](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/enabling-message-signaled-interrupts-in-the-registry) — ключ `MSISupported`
