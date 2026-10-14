# Сумісність і рушії Portico

Перевірено за першоджерелами **5 вересня 2026 року**. Це межі першої версії та план перевірки; сумісність конкретної гри не підтверджується наявністю картки в бібліотеці або успішним `wine --version`.

## Бібліотека різних ігор

Portico не обмежений фіксованим списком назв. Для кожної доданої напряму `.exe`-гри зберігаються власні файл запуску, середовище, аргументи й робоча папка; якщо поле порожнє, використовується каталог `.exe`. Ці параметри можна змінити в наявній картці. Імпортовані Steam-ігри запускаються через Windows-клієнт Steam; параметри їх запуску задаються в самому клієнті. Окремі середовища дають змогу незалежно налаштовувати й зупиняти ігри, але сумісність перевіряється для конкретної версії гри та рушія.

## Цільові ігри для перевірки

| Гра | Підтверджено видавцем | Практичний шлях |
|---|---|---|
| **Heroes of Might and Magic III, оригінал / Complete** | Complete включає основну гру та доповнення Armageddon’s Blade і The Shadow of Death. | Встановити власну копію в окреме Wine-середовище, вибрати її `.exe` та за потреби робочу папку. Перевірити карту пригод, місто, бій і збереження. **На цьому етапі в Portico ще не перевірена.** |
| **Jagged Alliance 2, оригінал / Gold** | Gold включає оригінальну Jagged Alliance 2 і доповнення Unfinished Business. В опублікованих вимогах зазначено Windows 95/98, SVGA та DirectX-сумісну звукову карту. | Перевіряти основну гру в окремому Wine-середовищі, з її `.exe` та каталогом даних. Низькі історичні вимоги не доводять сумісності із сучасним Wine на Mac. **У Portico ще не перевірена.** |
| **Divinity: Original Sin 2 — Definitive Edition** | Є окрема **macOS-версія**. Windows-версія використовує DirectX 11. У вимогах macOS зазначено 8 ГБ RAM і 20 ГБ місця; перелічено підтримувані Intel Mac. | Спочатку запускати macOS-версію через встановлений Steam або `.app`. Наявність Mac-порту не доводить наявності ARM64-бінарного файлу або продуктивності на конкретному Apple Silicon. Windows-версію випробовувати окремо за потреби. |
| **Gothic 1 Remake** | Windows 10/11 64-bit, **DirectX 12**, щонайменше 16 ГБ RAM, відеокарта з 8 ГБ VRAM (RTX 2070 / RX 6700 XT), 60 ГБ місця й SSD. Рекомендовано 32 ГБ RAM. macOS у системних вимогах немає. | Експериментальна ціль для окремого рушія з робочим DX12 → Metal. Базовий Wine-профіль Portico не має підтвердженої підтримки цієї гри. |

Джерела: [Jagged Alliance 2 Gold у Steam](https://store.steampowered.com/app/1620/Jagged_Alliance_2_Gold/), [Divinity: Original Sin 2 у Steam](https://store.steampowered.com/app/435150/Divinity_Original_Sin_2__Definitive_Edition/?l=english), [Gothic 1 Remake у Steam](https://store.steampowered.com/app/1297900/Gothic_1_Remake/?l=english).

Для Heroes III фіксувати видання, магазин, мову й версії модифікацій. Оригінал / Complete, HD Edition, HD Mod і Horn of the Abyss (HotA) — окремі варіанти перевірки; результат чистої інсталяції не підтверджує роботу модів. HD Edition і HD Mod не слід змішувати в протоколі. Джерела: [склад Complete на GOG](https://www.gog.com/en/game/heroes_of_might_and_magic_3_complete_edition), [HD Edition у Steam](https://store.steampowered.com/app/297000/).

Для JA2 завжди фіксувати видання, мову, версію й модифікації. Оригінал / Gold, Unfinished Business і мод 1.13 — окремі варіанти перевірки; результат одного не поширюється на інші.

**Додатковий шлях для JA2 на macOS — Stracciatella.** Проєкт пропонує власний кросплатформний рушій і macOS-застосунок, якому потрібні дані чистої інсталяції оригінальної гри. Інструкція прямо виключає інсталяцію з модом 1.13. Це окремий запуск поза Wine; автоматичного встановлення або інтеграції Stracciatella в Portico поки немає. [Опис проєкту](https://ja2-stracciatella.github.io/), [офіційна інструкція](https://ja2-stracciatella.github.io/how-to-run/).

Тут розглядається **Gothic 1 Remake**. Оригінальна Gothic 2001 року та її модифікації — інші цілі з іншими вимогами. Вимоги Windows GPU не можна прямо прирівнювати до обсягу спільної пам'яті Mac.

## Що робить перша версія

Portico — самостійний інтерфейс для бібліотеки й Wine-префіксів. Wine реалізує Windows API; трансляцію машинних інструкцій і сучасної 3D-графіки забезпечують окремі компоненти. Сам інтерфейс не створює підтримки нових API. [Опис WineHQ](https://www.winehq.org/).

Обсяг MVP: підключити локальний `wine`, створити окремий префікс для гри, запустити інсталятор або `.exe`, встановити Windows Steam, імпортувати повністю встановлені ігри з його локальних маніфестів і запускати їх за App ID, відкрити налаштування Wine, зберегти параметри запуску та журнал. **Рушій і Windows-ігри до дистрибутива не входять.** Steam, DRM, античити, відеокодеки, контролери й графіка потребують перевірки в конкретній грі. FPS і сумісність Gothic тут не заявлені.

## Вибір Wine на macOS

Уже встановлену відповідну збірку можна виявити за такими шляхами:

```text
/opt/homebrew/bin/wine
/usr/local/bin/wine
/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine
/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine
/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine
```

Це кандидати для перевірки, а не гарантія наявності. Абсолютний шлях користувача має пріоритет. Виконуваний файл потрібно перевірити через `--version`, а `wineserver` брати з тієї самої інсталяції. Опублікована Homebrew-збірка Wine Stable розрахована на **Intel macOS**, тому на Apple Silicon їй потрібна Rosetta 2. [Homebrew Wine Stable](https://formulae.brew.sh/cask/wine-stable), [Wine Devel](https://formulae.brew.sh/cask/wine@devel).

Підключення зовнішнього рушія експериментальне. Самостійний Wine і внутрішній wrapper CrossOver мають різні контракти: офіційний посібник CrossOver для Mac показує `wine --bottle … --cx-app …`. Сам `WINEPREFIX` не підтверджує коректної ізоляції довільного wrapper CrossOver. Тому такий runtime потребує окремого адаптера й тесту, а успішного `--version` недостатньо. [Посібник CrossOver для Mac](https://www.codeweavers.com/support/docs/crossover-mac/index).

На дату перевірки Homebrew позначає `wine-stable` як **disabled із 2026-09-01**, причина `fails_gatekeeper_check`. `wine@devel` також disabled. Тому команда `brew install --cask wine-stable` не пропонується як гарантовано робочий спосіб встановлення. У звичайній локальній збірці Portico можна підключити готовий рушій або кнопкою завантажити закріплену збірку Gcenx Wine 11.0_1, перевірити SHA-256 і розпакувати її у власний каталог `Runtimes`. Запуск дозволяється лише після оцінювання безпеки macOS і перевірки Wine. Gatekeeper не вимикається; завантаження цієї збірки не гарантує проходження перевірки macOS. [Метадані Homebrew](https://formulae.brew.sh/api/cask/wine-stable.json).

У Wine 11.0 завантажувач `wine64` видалено: використовується **єдиний `wine`**. Новий WoW64 оголошено повноцінно підтримуваним: він запускає 32-bit Windows-код у 64-bit середовищі. Окремі префікси `WINEARCH=win32` у новому WoW64 не підтримуються. Для MVP слід створювати стандартний 64-bit префікс, не перемикаючи архітектуру вже наявного. [Примітки до випуску Wine 11.0](https://github.com/wine-mirror/wine/blob/wine-11.0/ANNOUNCE.md).

ARM64 Wine — окремий напрям, що розвивається. CodeWeavers 31 липня 2026 року випустила експериментальний CrossOver Preview з ARM64 Wine та адаптованим FEX; ARM64-компоненти потребують macOS 26.5+. В анонсі цієї збірки зазначено відсутність D3DMetal/DX12, проблеми ігрових лаунчерів і необхідність нових bottles. Це **стан оголошеної Preview-збірки**, а не обіцянка поточних можливостей будь-якого Wine. [Анонс CodeWeavers](https://www.codeweavers.com/blog/mjohnson/2026/7/31/crossover-preview-the-right-to-bear-arm64-on-mac), [повідомлення розробника Wine від 7 серпня 2026 року](https://list.winehq.org/hyperkitty/list/wine-devel%40list.winehq.org/message/CKG5CEN2BE5VRXZ7O7NX4YUSBH3247WH/).

## Команди та ізоляція

Приклад нижче показує протокол запуску, а не інсталяційний скрипт. Підставляються вже вибраний рушій і шлях до префікса:

```sh
PORTICO_WINE='/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine'
PORTICO_BIN='/Applications/Wine Stable.app/Contents/Resources/wine/bin'
PORTICO_PREFIX='/absolute/path/to/bottle'

"$PORTICO_WINE" --version
WINEPREFIX="$PORTICO_PREFIX" "$PORTICO_WINE" wineboot --init
WINEPREFIX="$PORTICO_PREFIX" "$PORTICO_BIN/wineserver" --wait
WINEPREFIX="$PORTICO_PREFIX" "$PORTICO_WINE" winecfg
WINEPREFIX="$PORTICO_PREFIX" "$PORTICO_WINE" '/absolute/path/to/setup.exe'
WINEPREFIX="$PORTICO_PREFIX" "$PORTICO_WINE" msiexec /i '/absolute/path/to/setup.msi'
```

`wineboot --init` створює середовище. `wineserver --wait` дає змогу дочекатися завершення Wine-сесії, включно з дочірніми процесами інсталятора. Для зупинення конкретної сесії застосовується `wineserver --kill` із **тим самим WINEPREFIX**: зупиняться всі застосунки цього префікса. Це не глобальний `killall`. [Посібник wineboot](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.0/programs/wineboot/wineboot.man.in), [посібник wineserver](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.0/server/wineserver.man.in).

У застосунку процес запускається через `Process.executableURL` і масив аргументів. Назви ігор та шляхи не інтерполюються в shell-команду. Середовище процесу отримує абсолютний `WINEPREFIX` і каталог вибраного Wine в `PATH`. Змінні графічних розширень задаються лише для рушія, який їх підтримує. Префікс розділяє налаштування, реєстр і Wine-сесії; **це не пісочниця безпеки для недовіреного `.exe`**.

## Windows Steam

Розділ Steam використовує Windows `SteamSetup.exe`, який завантажується з адреси, зазначеної на [офіційній сторінці Steam](https://store.steampowered.com/about/): [Windows-інсталятор Valve](https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe). Інсталятор запускається інтерактивно в готовому Wine-префіксі. Оновлення Steam, вхід, Steam Guard, завантаження ігор і встановлення залежностей першого запуску залишаються діями самого клієнта.

Portico передає фіксовані адреси бібліотеки, магазину й завантажень та App ID гри безпосередньо `steam.exe` у тому самому `WINEPREFIX`. Системний обробник `steam://` macOS для цих дій не використовується. Valve також використовує URI `steam://` у документації, наприклад для [відкриття консолі Steam](https://partner.steamgames.com/doc/features/cloud) і [запуску за App ID](https://partner.steamgames.com/doc/sdk/uploading/distributing_source_engine). Це не є підтвердженням роботи клієнта під Wine.

Імпорт орієнтується на локальні маніфести повністю встановлених ігор Windows-клієнта вибраного середовища. Він не синхронізує хмарну бібліотеку облікового запису й не додає частково завантажену гру як готову. Картка зберігає App ID і середовище; встановлення й запуск гри відбуваються через клієнт Steam. Наявні картки без App ID продовжують використовувати попередній шлях `.exe`.

Сесія Steam може приймати команди Portico, поки клієнт працює. Загальні операції встановлення й налаштування середовища не мають конкурувати із цією сесією. Зупинення префікса завершує і Steam, і запущені ним ігри. Стан Wine-сесії не доводить наявності ігрового вікна або коректності 3D-рендерингу.

**На дату цього документа фактичне встановлення, вхід, завантаження й запуск Windows Steam у Portico ще не пройшли ручної перевірки.** Сумісність графіки, DRM і античита оцінюється окремо для кожної гри за сценарієм [ручної перевірки](MANUAL_TESTING.md). Додавання клієнта не постачає DX11/DX12 runtime й не підтверджує підтримку Gothic 1 Remake.

## Графічні компоненти

| Компонент | Підтверджене призначення | Рішення для MVP |
|---|---|---|
| WineD3D | Графічна реалізація Wine; Wine 11 продовжує розвивати OpenGL/Vulkan-рендерери. | Використовувати можливості встановленої збірки. Не позначати DX12 готовим лише за наявністю Wine. |
| DXVK | Реалізація D3D8/9/10/11 поверх Vulkan. DXVK 3.x потребує Vulkan 1.4 **і конкретного набору можливостей драйвера**. | Не копіювати випадкові DLL і не обіцяти роботу Linux-налаштування на Mac. Сам DXVK не вирішує DX12 для Gothic. |
| MoltenVK | Реалізує підмножину Vulkan поверх Metal; обмеження перелічено розробниками. | Збігу номера Vulkan недостатньо: потрібен перевірений комплект Wine + DXVK + MoltenVK. |
| GPTK / D3DMetal | Apple пропонує середовище оцінювання Windows-ігор на Apple Silicon; сторінка GPTK 4 описує підтримку Metal 4. | Планувати окремий адаптер перевіреного runtime. Вбудованої підтримки й автоматичного постачання D3DMetal у MVP немає. |

Джерела: [Wine 11.0](https://github.com/wine-mirror/wine/blob/wine-11.0/ANNOUNCE.md), [DXVK](https://github.com/doitsujin/dxvk), [вимоги драйвера DXVK](https://github.com/doitsujin/dxvk/wiki/Driver-support), [MoltenVK](https://github.com/KhronosGroup/MoltenVK/blob/main/README.md), [Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/).

Wine розповсюджується за LGPL 2.1 або пізнішою версією. Ліцензування Wine й постачання закритих графічних компонентів — окремі питання: перша версія постачає власний інтерфейс без копіювання CrossOver та Apple runtime. Для майбутнього постачання конкретного рушія потрібно враховувати ліцензії саме його компонентів. [Ліцензія Wine](https://github.com/wine-mirror/wine/blob/wine-11.0/LICENSE).

## Коли гру можна позначити перевіреною

Зафіксувати модель Mac, пам'ять, версію macOS, версію й архітектуру рушія, графічний backend, магазин, build і модифікації гри. Перевірити запуск із нової bottle, меню, щонайменше 15 хвилин ігрового процесу, звук і керування, створення збереження, завантаження після повного перезапуску та журнал помилок. Для JA2 включити тактичний бій. Успішний тест невеликого `.exe` підтверджує механізм запуску, а не сумісність цільових ігор.
