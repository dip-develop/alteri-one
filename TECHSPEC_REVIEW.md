# Ревью `TECHSPEC_AND_TASKS.md` — замечания, правки, дополнения, оптимизация

> Дата: 2026-09-25. Проверено: Dart stable 3.13.4, Flutter 3.47.5, melos 8.9.0,
> MCP spec revision `2026-07-28`, pub.dev-состояние пакетов, реальные возможности
> `dart:isolate` / `dart:compile`. Ниже — только то, что подтверждено источниками
> или следует из кода спеки; домысливаний нет.
>
> Документ не заменяет спеку, а предлагает конкретные изменения к ней. Целевая
> аудитория — автор спеки и исполнитель Фазы 0.

---

## 0. TL;DR

Спека сильная по духу (протокольная дисциплина, time-boxing, fail-soft, versioned
envelope) и правильно выбирает OpenAI-compatible как единый wire. Но в текущем виде
**план упирается в три блокера, каждый из которых ломает либо код, либо сам план работ**:

| # | Блокер | Где | Почему блокер |
|---|---|---|---|
| **B1** | «Sandbox = `dart:isolate` + resource limits + env-прокси + network allowlist» | §3.5, §17.5, задача 0.4 | **Функционально неверно.** `dart:isolate` — не граница безопасности. `Platform.environment`, `dart:io exit()`, FFI/`DynamicLibrary.open`, `Process.start` и VM Service дают произвольному Dart-коду полномочия всего процесса. Пер-изолятных лимитов CPU/памяти в API не существует. Acceptance задачи 0.4 («недоверенный модуль в isolate не видит секреты core») — фальсифицируемое утверждение, оно упадёт. |
| **B2** | «Dart не умеет грузить код в рантайме» подразумевается в §3.2 (`load (dynamic import)`) и в §14 Фаза 4.2 (маркетплейс) | §3.2, §14 | В Dart **нет** загрузчика классов. `Isolate.spawnUri` — единственная узкая лазейка, и она в том же процессе. Значит маркетплейс = build-time зависимости (доверенные) **или** отдельные AOT-exe по протоколу (недоверенные). Это не деталь реализации, это половина дизайна экосистемы — и её нет в плане. |
| **B3** | Один `core` на CLI + Flutter app + Flutter web | §2 (правила зависимостей), §15.3 | `dart:io` на web не существует, `dart:isolate` на web не существует вообще. `alteri_one_sandbox` (в правилах зависимостей — зависимость `core`) — `dart:io`-зависимый. Значит текущее правило зависимостей **несовместимо** с web-таргетом, а слой платформенных абстракций в плане отсутствует. |

Плюс фактические ошибки, которые надо исправить до первой строки кода:

- `pubspec.workspaces.yaml` **не существует**; melos 8 конфигурируется в корневом `pubspec.yaml`.
- `hive` 2.2.3 имеет SDK-ограничение `>=2.12.0 <3.0.0` — **несовместим с Dart 3.13 вообще**. Нужен `hive_ce`. Пакетов `hive`/`hive_adapters` в актуальном состоянии нет.
- Пакетов OpenTelemetry `open-telemetry` / `otlp_client` на pub.dev **нет**.
- YAML в §5.1 и §5.2 **не парсится** (проверено: `ScannerError: mapping values are not allowed here`).
- MCP ревизии `2026-07-28` — это **не** vanilla JSON-RPC 2.0: нет `initialize`, нет batching, есть per-request `_meta`. «Бесплатная MCP-интероп» из §1/§12 неверна.
- В §18 перечислены языковые фичи, которых в Dart нет (`dart:primary-constructor`, «sequence-циклы», `?[]` как null-aware элемент коллекции), и не указаны версии, где фичи реально стабилизировались.

**Главная рекомендация по плану:** вынести песочницу недоверенных модулей из **Фазы 0** в отдельную позднюю фазу, а marketplace начать с **декларативных skill-паков (данные, без кода)**. Это снимает главный риск расписания: сейчас самый дорогой, самый исследовательский и самый вероятно-неверно-оценённый компонент стоит как gate в самом начале.

---

## 1. Карта замечаний по разделам

| § | Проблема | Что делать | Приоритет |
|---|---|---|---|
| 1 | Sandbox и «бесплатная MCP-интероп» заявлены как решённые решения | Переформулировать: песочница — tiered-модель, MCP — платная подсистема | P0 |
| 1 | Нет позиционирования и north-star метрик | Добавить §1.1 (ниже) | P0 |
| 2 | `pubspec.workspaces.yaml` не существует; melos 8 layout другой | Переписать layout (§2 ниже) | P0 |
| 2 | Правило зависимостей несовместимо с web | Добавить `alteri_one_platform`, пересмотреть граф | P0 |
| 2 | `config/` в репозитории ≠ рантайм-конфиг AOT-бинаря | Разделить seed/fixtures и рантайм-пути | P1 |
| 3.1 | `manifest(): Map<String, dynamic>` — нет валидации схемы | Типизированный манифест + валидация + версия | P0 |
| 3.2 | «load (dynamic import)» невозможен в Dart | Статический registry (trusted) / out-of-process (untrusted) | P0 |
| 3.3 | Нет хендшейка версий между ядром и модулем | `core.initialize` с negotiation | P0 |
| 3.5 | **Ключевая ошибка** | Полная замена: три тира исполнения (§3.5 ниже) | P0 |
| 4 | Нет фрейминга, лимитов размера, отмены, negotiation | Дополнить протокол (§4 ниже) | P0 |
| 4 | Метаданные `version` неоднозначны (протокол vs модуль) | Разделить `proto` и `moduleVersion` | P1 |
| 5.1/5.2 | **YAML невалиден**; нет `apiVersion`; permissions — свободная форма | Новая схема (§5 ниже) | P0 |
| 5.2/5.4 | Хуки продублированы в двух местах, нет прецедента | Одна подсистема policy (§5.3 ниже) | P0 |
| 5.3 | `language: ru` без плана i18n | `intl` с Фазы 0 | P1 |
| 6 | Нет стриминга, нет учёта usage, нет capability matrix, нет failover | Расширить интерфейс (§6 ниже) | P0 |
| 6 vs 8 | **Сигнатура не сходится**: `messages`/`model` — required named, вызов позиционный | Согласовать (§8 ниже) | P0 |
| 7 | `hive` несовместим; «опция вектора» невыполнима на Hive; нет схемы записей | `hive_ce` + интерфейс `VectorIndex`; типизированные записи памяти | P0 |
| 7 | Нет provenance/confidence/TTL/delete/export | Добавить (§7.1 ниже) | P1 |
| 8 | **7 дефектов в псевдокоде** | Переписать цикл (§8 ниже) | P0 |
| 9 | Нет бюджета/глубины/конкурентности у subagents | Добавить инварианты | P1 |
| 10 | Hooks = подмножество policy; дублируется | Объединить с policy | P1 |
| 11 | «автотест-ядро» смешивает юнит-тесты и evals; нет детерминизма | Два уровня + replay (§11 ниже) | P0 |
| 12 | MCP ≠ vanilla JSON-RPC; «бесплатно» | Реальный SDK, ревизия, слой маппинга | P0 |
| 13 | `dart compile exe` падает при build hooks; нет релиза/подписи | `dart build cli`; CI-релиз | P1 |
| 14 | Песочница — в Фазе 0 (главный риск); нет fake provider; acceptance немашиночитаемы | Новый порядок фаз (§14 ниже) | P0 |
| 15 | 5 открытых вопросов — часть уже отвечена неверно | Закрыть с ответами | P0 |
| 16 | `melos init` не актуален для melos 8 | Новые команды | P1 |
| 17 | Принцип 2 слишком силён и будет нарушен; принцип 1 противоречит §8 | Переписать + security-инварианты | P0 |
| 18 | Несуществующие фичи и пакеты; нет версий | Исправленный список | P0 |

---

## 2. ИЗМЕНЕНИЯ: фактические правки

### 2.1 Monorepo (новый §2)

```yaml
# корень: pubspec.yaml
name: alteri_one_workspace
publish_to: none
environment:
  sdk: ^3.13.0

workspace:            # Dart ≥3.6; глобы — Dart ≥3.11
  - packages/*
  - applications/*
  - sdk/*

dev_dependencies:
  melos: ^8.9.0
  build_runner: ^2.16.1

melos:
  command:
    version:
      versionPrivatePackages: true
  scripts:
    test: melos exec -c 1 --fail-fast -- dart test
    analyze: melos exec -c 1 -- dart analyze --fatal-infos
    generate: melos exec -c 1 --depends-on="^build" -- dart run build_runner build
    aot: melos exec -c 1 --scope="alteri_one_cli" -- dart build cli
```

```yaml
# каждый пакет
name: alteri_one_core
resolution: workspace
environment:
  sdk: ^3.13.0
```

Что поменять и почему:
- `melos.yaml` → секция `melos:` в корневом `pubspec.yaml` (так в melos 8; `melos.yaml` — легаси).
- Убрать `pubspec.workspaces.yaml`: такого файла в Dart нет.
- `pubspec.lock` коммитить (melos 8 явно на это указывает).
- `melos bootstrap` больше не обязателен для линковки локальных пакетов — pub workspaces делают это сами. Он остаётся для скриптов и версионирования.
- **Корень не должен быть пакетом** (нет `name:`-пакета с библиотекой) — это конфликтует с «recommended: не кладите пакет в корень».

### 2.2 Правила зависимостей (исправление под web-таргет)

Текущее «`core` зависит только от `protocol` и `sandbox`» нельзя реализовать: `sandbox` — это `dart:io` + OS, а `core` должен собираться в web. Предлагаемый граф:

```
alteri_one_protocol      # ноль зависимостей; dart:core-only; ни dart:io, ни dart:mirrors
        ▲
        │        alteri_one_platform   # conditional imports: dart:io | package:web
        │        (storage, process, concurrency, http, clock, paths)
        │                  ▲
alteri_one_core ──────────┘        # движок: loop, registry, bus, policy, budget
        ▲
        │   alteri_one_memory        # storage impl (native) + vector index (опц.)
        │   alteri_one_providers
        │   alteri_one_skills
        │   alteri_one_mcp
        │   alteri_one_subagents
        │   alteri_one_tracing
        │   alteri_one_sandbox       # НЕ зависит от core; зависит от platform
        ▼
alteri_one_sdk                       # re-export
        ▼
applications/{cli,app,web}
```

Ключевые правки:
- `alteri_one_sandbox` **не** зависит от `core` и **не** импортируется им: это инфраструктура хоста, а не capability.
- Добавить `alteri_one_platform` — единственное место, где живут `dart:io` / `package:web`. Это делает «одно ядро, три фронтенда» реализуемым, а не декларативным.
- Интерфейсы, которые обязаны быть в `platform`: `AlteriOneStorage`, `AlteriOneProcessHost`, `AlteriOneConcurrency`, `AlteriOneHttpClient`, `AlteriOneClock`, `AlteriOnePaths`. Последние два — обязательны ещё и ради детерминизма тестов (§11).

### 2.3 Пакеты: что заменить

| В спеке | Статус | Замена |
|---|---|---|
| `hive` + `hive_adapters` | ❌ `hive` 2.2.3: SDK `>=2.12.0 <3.0.0`; `hive_adapters` как пакет не существует | `hive_ce ^2.20.0` + `hive_ce_generator` |
| `open-telemetry` + `otlp_client` | ❌ таких пакетов нет | `opentelemetry` 0.18.x (traces — Beta) либо `dartastic_opentelemetry`; экспорт только OTLP/HTTP. Честно пометить «pre-1.0, community» |
| `freezed` (любая) | ⚠️ 3.x генерил нелегальный `final`-параметр под Dart 3.13 | `freezed ^4.0.2` + `json_serializable ^6.14.1` + `build_runner ^2.16.1` |
| `cli_pkg` | ⚠️ Grinder-релизы; для нового CLI — `dart build cli` / `dart install` | `args ^2.7.0` для парсинга; `dart build cli` для дистрибуции |
| «vanilla JSON-RPC 2.0 (`http`)» для MCP | ❌ диалект 2026-07-28 существенно отличается | `dart_mcp` 0.5.2 (official, **experimental**) или `mcp_dart` 2.4.2 (community, поддерживает 2026-07-28) |
| `openai_dart` «или `http`» | ⚠️ неопределённость | `package:http` + свои типы. Смысл — «единый wire = OpenAI-compatible», а не «использовать чужой SDK с чужими opinionated типами» |

### 2.4 §18 «Современный Dart» — исправленный список

Убрать: `dart:primary-constructor` (такой библиотеки нет; primary constructors — синтаксис, стабилен в 3.13), «sequence-циклы `for (x in {a,b,c})`» (такого термина и синтаксиса нет), `?[]` как null-aware элемент коллекции (нужен `?expr`), `?.call()` в списке «нового в 3.13» (это условный вызов, гораздо старше).

Заменить на таблицу с версиями — она же служит проверкой, что CI не соберётся на старом SDK:

| Фича | Стабильна с |
|---|---|
| patterns / records / switch-экспрессии | 3.0 |
| null-aware элементы коллекций (`?expr`) | 3.8 |
| dot shorthands (`.blue`) | 3.10 |
| primary constructors + concise `new`/`factory` | **3.13** |
| `async*`, extensions, `Isolate.run`, FFI | 3.0 |

Зафиксировать в `analysis_options.yaml` `language: { strict-casts: true, strict-raw-types: true }` — для AOT-ядра это даёт бесплатную защиту от неявных `dynamic` в протоколе.

---

## 3. ИЗМЕНЕНИЯ: безопасность (переписать §3.5 и §17.5)

### 3.1 Что в текущем §3.5 неверно

| Заявлено | Реальность |
|---|---|
| «недоверенный модуль → свой isolate» | Изолят — граница конкурентности и частично — локализация ошибок. **Не** граница безопасности |
| «resource limits (memory)» | Пер-изолятных лимитов CPU/памяти в API Dart **нет**. `Isolate.spawn` не имеет параметров лимитов. `--old_gen_heap_size` — флаг VM на isolate-группу, не считает FFI/native/стеки |
| «network allowlist (hosts + methods)» | В процессе не enforceable: `HttpClient`, `Socket`, `RawSocket`, `InternetAddress.lookup`, `Process`. `HttpOverrides` — не песочница |
| «проксированные env, ключи не видны модулю» | `Platform.environment` читается из любого изолята. `spawnUri(environment:)` — это compile-time-конфигурация (`String.fromEnvironment`), не POSIX-env, и не scrub |
| «краш модуля не роняет core» | Верно для обычных исключений. `dart:io exit()` убивает **процесс**. FFI + `DynamicLibrary.open()` даёт полный доступ к libc. В JIT/observed-режиме `Service.getInfo()` отдаёт URI VM Service, через который можно звать `evaluate`/`getObject`/`kill` на других изолятах |
| «validate (манифест + хэш/подпись)» | Подпись доказывает происхождение, не поведение |

Вывод: acceptance задачи 0.4 нужно **удалить и заменить**, а не переформулировать.

### 3.2 Новая §3.5 — три тира исполнения

> **Названия тиров — это и есть политика безопасности проекта. Не переименовывайте их в «worker»,
> иначе через полгода кто-то решит, что tier 2 можно запустить в изоляте.**

**Tier 0 — Skill Pack (данные, без кода).**
Папка: `SKILL.md` + ресурсы + опционально скрипты. Не исполняется ядром, не имеет прав,
инжектится в контекст как недоверенный контент. Низкий риск. Формат выровнять с открытой
спецификацией Agent Skills (agentskills.io) и механизмом Dart package skills — тогда
экосистема совместима, а не изобретена заново. **Marketplace начинается здесь.**

**Tier 1 — Trusted Module (код, в процессе).**
Первопартийный или ревьюнутый код, линкуется в AOT-бинарь на этапе сборки. Регистрация —
через codegen, не через рантайм-сканирование. Изолят (если нужен) — только для
локализации ошибок и честного разделения CPU. **Явно не граница безопасности.**
Может иметь `AlteriOneRuntime`.

**Tier 2 — Untrusted Module (код, вне процесса).**
Произвольный код из маркетплейса. Никогда не линкуется в ядро, никогда не в изоляте ядра.

```
Process.start(
  executable: <precompiled AOT exe модуля>,   // НЕ из manifest, а из подписанного реестра
  includeParentEnvironment: false,            // env собирается явно и минимально
  workingDirectory: <tmpfs workspace>,       // не ~/, не cwd ядра
)
  + OS sandbox: Linux bwrap/nsjail + cgroup v2 (memory.max, cpu.max, pids.max) + seccomp
  + сеть: network namespace выключен; наружу только unix-сокет брокеру
  + IPC: stdio/Unix-сокет, JSON-RPC, max frame size, deadline, отмена
  + kill по таймауту — вся группа процессов (cgroup.kill), не только PID
  + секреты: НЕ в env, НЕ в argv, НЕ в файлах. Модуль получает opaque capability id,
    брокер выполняет авторизованную операцию и подставляет креды в точке вызова
  + манифест декларирует capability; enforcement = пересечение с политикой
    (профиль ⊇ пользователь ⊇ админ ⊇ деплой)
  + при невозможности запустить sandbox — **fail closed**, не откат на изолят
```

**Платформенная политика (написать в спеку явно):**
- **Linux** — Tier 2 поддерживается первым (bwrap/nsjail — реалистично для Dart AOT-бинаря).
- **macOS / Windows** — до появления платформенного supervisor'а Tier 2 **не поддерживается**.
  Отказ — явный и видимый. Молчаливый откат на изолят запрещён.
- **Web** — Tier 1/2 не поддерживаются вовсе (нет `dart:io`, нет изолятов).

**Wasm-компоненты** — долгосрочно правильный ABI плагинов (linear memory, явные imports,
fuel/epoch, лимиты), но `dart compile wasm` сегодня не работает в Wasmtime/Wasmer
(открытые issue 53884, 56366). В Фазу 0–4 не входит.

### 3.3 Новая §17.5 — инварианты безопасности

1. Произвольный сторонний код не исполняется в VM ядра и не в изоляте ядра.
2. Секрет ядра недоступен через env модуля, argv, унаследованные дескрипторы, объекты
   рантайма, VM Service или неограниченный ФС-доступ.
3. Модуль получает **capabilities**, а не окружающую власть.
4. Сеть запрещена по умолчанию; любой сетевой вызов идёт через брокер, который
   проверяет destination, метод, redirect, размер, креды и rate limit.
5. Лимиты ресурсов обеспечиваются **вне Dart** (cgroups / Job Objects / supervisor).
6. У каждого запроса есть максимальный размер, дедлайн, лимит конкурентности и путь отмены.
7. Недоверенный текст и вывод инструментов несут provenance и **сами по себе не авторизуют** действия.
8. Внешние записи, отправка сообщений, использование кредов, разрушительные операции —
   требуют детерминированной политики и, где нужно, подтверждения человека.
9. Подпись/верификация = происхождение, не безопасность.
10. Отказ sandbox, недоступность брокера, некорректный манифест, нарушение политики →
    **отказ**, не деградация к более слабому режиму.

### 3.4 Пропущенная угроза: prompt injection

В специ нет модели недоверенного контента вообще, хотя §4 уже тащит `context: {...}` извне.
Нужна минимальная база:

- **Lethal trifecta** (доступ к приватным данным + недоверенный контент + возможность
  связи наружу) — разрывать детерминированно, а не «улучшенным системным промптом».
  Защита по классу: не давать недоверенному контексту управляющие права; не давать
  внешнюю эмиссию без политики; данные и инструкции — разные каналы.
- **Provenance-метки** на границах типов, а не «попросим LLM классифицировать»:
  `trusted_user`, `untrusted_web`, `untrusted_email`, `untrusted_tool_output`, `private_data`,
  `secret`. Помечаются в **детерминированном host-коде**, не в тексте промпта.
- **Узкие типизированные capabilities** вместо `runShell(command)` / `fetch(url)`:
  `createCalendarEvent(validatedFields)`, `fetchDocument(documentId)`. Проверка полномочий
  — в брокере/на стороне сервиса (complete mediation), а не «спросим модель, можно ли».
- **Инструкции MCP-сервера не вставляются в системный промпт**; tool descriptions
  показываются пользователю целиком (tool poisoning — реальный вектор, incl. скрытые
  аргументы).
- Никаких «игнорируй инструкции внутри вывода инструмента» / детекторов инъекций —
  исследования (в т.ч. arXiv 2506.08837) показывают, что это defense-in-depth, не граница.

---

## 4. ИЗМЕНЕНИЯ: протокол (дополнить §4)

Текущий §4 описывает только форму сообщения. Для реальной работы не хватает шести вещей.

**(а) Фрейминг.** «stdio JSON-RPC» без фрейминга — не спецификация. Взять LSP-подход:
заголовок `Content-Length: <bytes>\r\n\r\n` + payload. NDJSON не подойдёт для бинарных
вложений и хрупок на частичных чтениях; LSP-фрейминг это уже решил.
Добавить: `maxFrameBytes` (по умолчанию 8 MiB), backpressure на отправителе.

**(б) Отмена.** Сейчас в loop нет ни `CancelToken`, ни abort. Time-boxed loop, который
нельзя прервать из терминала, — продуктово мёртв. Ввести `$/cancelRequest`
(JSON-RPC notification) + `CancelToken`, который **каскадирует** в subagents и в
sandbox-процесс (kill группы).

**(в) Прогресс.** `$/progress` — иначе CLI на этапе 0 выглядит зависшим.

**(г) Handshake и negotiation.** Разные модули = разные версии. Обязателен `core.initialize`:
`{protoVersionRange, moduleVersion, capabilities, limits}` → `{negotiatedProto, accepted,
degradePolicy}`. Политика при несовпадении: refuse / warn+degrade — выбирается явно, не
неявно. Это то, чего маркетплейс не может без нас.

**(д) Метаданные.** `version` в конверте неоднозначно. Разделить:
`proto` (версия конверта/протокола) и `moduleVersion` (semver манифеста).

**(е) Таксономия ошибок.** Сейчас «retryable flag» — единственное упоминание. Нужна таблица,
иначе retry-логика в §8 неопределённа:

| Code | Смысл | Retry | Скормить модели |
|---|---|---|---|
| −32700 / −32600 / −32601 / −32602 | parse / invalid request / method / params | нет | params — да |
| −32603 | internal | возможно | да |
| −32001 | провайдер недоступен (retryable) | backoff | да |
| −32002 | rate limited (+ `Retry-After`) | после Retry-After | нет |
| −32003 | модель отказала / content filter | нет | да |
| −32010 | инструмент завершился ошибкой | по capability | да |
| −32011 | таймаут инструмента | один retry | да |
| −32020 | **policy denied** | нет | да |
| −32021 | **approval declined** | нет | да |
| −32030 | deadline exceeded | нет | нет |
| −32031 | cancelled | нет | нет |
| −32032 | budget exhausted | нет | нет |
| −32040 | нарушение sandbox / модуль убит | нет | нет |
| −32050 | несовместимость версий | нет | нет |

(−32768…−32000 — диапазон, зарезервированный JSON-RPC под implementation-defined ошибки;
новые коды корректно располагаются там.)

**(ж) Sealed union вместо «одного `AlteriOneMessage` со всеми опциональными полями».**
В Dart это бесплатно и даёт compile-time exhaustive dispatch:

```dart
@freezed
sealed class AlteriOneEnvelope with _$AlteriOneEnvelope {
  const factory AlteriOneEnvelope.request({required String id, required String method,
      required Json params, required AlteriOneMeta meta, @Default(1) int proto}) = Request;
  const factory AlteriOneEnvelope.response({required String id, Json? result,
      AlteriOneError? error, AlteriOneMeta? meta}) = Response;
  const factory AlteriOneEnvelope.notification({required String method, required Json params})
      = Notification;
  const factory AlteriOneEnvelope.event({required String topic, required Json data,
      required String traceId}) = Event;
}
```

Отсутствие `id` у `Notification`/`Event` выражается типами, а не валидацией в рантайме;
`Response` обязан иметь ровно одно из `result`/`error` — это тоже проверяется компилятором.

---

## 5. ИЗМЕНЕНИЯ: конфигурация (переписать §5)

### 5.1 YAML в текущей спеке не парсится

§5.1 и §5.2 содержат блок, который любой YAML-парсер отвергает:

```yaml
permissions:
  - network: allow
      hosts: [maps.googleapis.com]     # ← отступ глубже ключа `network`
      methods: [GET, POST]
# ScannerError: mapping values are not allowed here (line 4, col 12)
```

Проверено. Плюс: `entrypoint: skill:run` смешивает модуль-относительный вход с
namespaced-методом. Пока схема не описана **и не покрыта тестом на парсинг всех
закоммиченных примеров**, любая правка конфигурации — лотерея.

### 5.2 Новая схема профиля

```yaml
apiVersion: alteri.one/v1        # обязательное; enables migration
kind: Profile
name: companion
persona:
  name: Alteri
  bio: |
    ...
  tone: тёплый, дружелюбный, без жаргона
  language: ru
model:
  providers:                     # цепочка, не один
    - id: openai
      baseURL: https://api.openai.com/v1
      apiKeyEnv: OPENAI_API_KEY
      modelId: gpt-4o
      requires: [tools, streaming]   # проверяется capability-пробой, см. §6
      temperature: 0.7
      maxOutputTokens: 4096
    - id: local
      baseURL: http://localhost:11434/v1
      modelId: qwen2.5
      requires: [streaming]
memory:
  enabled: true
  historyTurns: 60
  compaction:
    triggerTokens: 12000         # В ТОКЕНАХ, см. §8 — в спеке было смешение единиц
    keepLastTurns: 12
    maxSummaryTokens: 2000
policy:
  default: allow                 # allow | confirm | deny
  rules:                         # deny > confirm > allow, по возрастанию специфичности
    - match: {tool: shell_run}
      effect: confirm
    - match: {tool: file_delete}
      effect: confirm
    - match: {tool: file_delete, pathGlob: "~/.ssh/**"}
      effect: deny
    - match: {tool: file_read, pathGlob: "~/.env"}
      effect: deny
  egress:
    - {host: "api.github.com", methods: [GET]}
budgets:                          # НОВОЕ — см. §8
  maxSteps: 40
  deadline: 300s
  toolTimeout: 60s
  modelTimeout: 90s
  maxCostUsdPerRun: 0.50
  maxTokensPerRun: 500000
  stagnationWindow: 3
logging:
  format: jsonl                  # jsonl | human
  redaction: [secret, private_data]
```

**Правило типов:** `apiVersion` + `kind` + схема, валидируемая в коде (freezed/sealed),
с `alteri_one doctor --validate-config`, который печатает **файл, строку и путь
до поля**. Пользовательские YAML — это данные, у них обязана быть версия и путь миграции.

### 5.3 Хуки: одна подсистема вместо двух

Сейчас `hooks` есть и в профиле (§5.2), и в `config/hooks.yaml` (§5.4), без правила
прецедента, и смешивают три разные вещи: подтверждения, уведомления и (неявно)
автоматизацию. Свести к `policy` (правила выше) + `notifications` (отдельный список
чисто наблюдательных, без влияния на поведение). Прецедент: профиль → пользователь
(`~/.alteri_one/policies.d/`) → админ (`/etc` или путь деплоя) → деплой; `deny` побеждает
всегда, конфликты `allow` разрешаются в `deny`.

### 5.4 Конфиг в репозитории ≠ рантайм-конфиг

AOT-бинарь не должен зависеть от `config/` рядом с исходниками. Разделить:

1. **Встроенные дефолты** — в бинарь, как Dart-объекты (не YAML-строки, чтобы не
   тянуть `yaml` в рантайм для дефолтов и не ломать AOT-строки).
2. **Пользовательские** — `~/.alteri_one/` (`profiles/`, `policies.d/`, `modules/`, `state/`).
3. **Проектные** — `./.alteri_one/project.yaml` (для developer-профиля: репозиторий, тесты, команды).
4. **CLI-флаги** — высший приоритет.

Одинаково для `config/modules/*.yaml` → `~/.alteri_one/modules/`.

---

## 6. УЛУЧШЕНИЯ: провайдеры (§6)

Интерфейс из спеки не покрывает стриминг, учёт usage, зондирование возможностей и не
сходится с вызовом в §8 (там `messages`/`model` — required named, а передано позиционно —
это не компилируется). Предлагаемый интерфейс:

```dart
abstract interface class AlteriOneProvider {
  String get id;

  /// Что реально умеет эта конкретная связка endpoint+model.
  Future<AlteriOneModelCapabilities> probe();

  Stream<AlteriOneChatChunk> chat(
    AlteriOneRequest req, {
    required String model,
    required Deadline deadline,
    required CancelToken cancel,
  });
}
```

Что это даёт сверх спеки:

- **Стриминг с первого дня.** Спека откладывает стриминг («над ним»), но без него CLI
  выглядит сломанным, а переделывать интерфейс потом — больно. Стриминг в интерфейсе
  стоит почти ноль, retrofit стоит переписывания всех вызовов.
- **`AlteriOneModelCapabilities`** (`tools`, `parallelTools`, `streaming`, `jsonMode`,
  `promptCaching`, `seed`, `contextWindow`). «Модель-агностичность» через единый
  OpenAI-совместимый wire **не означает** одинаковый набор фич: локальные серверы
  часто не умеют `tools`, не все умеют JSON-mode и parallel tool calls. Без capability
  matrix «model-agnostic» — декларация. Матрица даёт и проверку в acceptance 0.7,
  и осознанный отказ вместо загадочной 400-й.
- **`providers: [...]` как цепочка** вместо одного `provider` в профиле: деградация при
  недоступности, плюс circuit breaker (спека обещает «fail soft» в принципе №4, но
  failover нигде не описан).
- **Usage обязателен в ответе** — без него нечем оплачивать бюджеты (§8).
- `requires: [tools]` в конфиге → ранняя проверка: «эта модель не умеет tools, выберите
  другую», вместо падения на середине ночи.

---

## 7. УЛУЧШЕНИЯ: память (§7)

Сейчас 4 строки и нереализуемое «опция вектора для recall» на Hive (у Hive нет ANN;
это KV-хранилище, он может только brute-force). Пакет `hive` вдобавок несовместим с Dart 3.

**Замена хранилища:** `hive_ce` (+`hive_ce_generator`) для KV/истории/фактов.

**Векторный recall:** за интерфейсом `VectorIndex`, реализацию — вне v1:

```dart
abstract interface class VectorIndex {
  Future<void> upsert(String id, List<double> embedding, {required Map<String,Object?> meta});
  Future<List<ScoredId>> query(List<double> q, {int k, Map<String,Object?> filter});
  Future<void> remove(String id);
}
```

Кандидаты: `sqlite3` + `sqlite-vec` (нативно, не web), `local_hnsw` (чистый Dart, web-совместим, но молодой — проверить зрелость и recall). Вектор в v1 не тащим: это заметный кусок работы без влияния на демо ядра.

**Записи памяти должны быть типизированными** — сейчас не сказано, что вообще хранится:

```dart
sealed class MemoryRecord {
  String get id; DateTime get createdAt; DateTime? get lastSeenAt;
  Provenance get provenance;     // user_stated | model_inferred | tool_observed
  double get confidence;         // 0..1
  DateTime? get ttl;             // забывание
}
final class FactRecord      extends MemoryRecord { final String key, value; }
final class EpisodeRecord   extends MemoryRecord { final String summary; final List<String> artifactIds; }
final class PreferenceRecord extends MemoryRecord { final String topic; final String pref; }
final class ArtifactRecord  extends MemoryRecord { final String path, mime, bytes; }
```

Правила, которых не хватает и без которых память станет источником инъекций:
- **provenance обязателен**: факт, сказанный пользователем, и факт, выдуманный моделью,
  — разные сущности. Модель не может записать в trusted-память то, чего пользователь не говорил.
- **Компакция не «промоутит»**: суммаризация не может перелить `untrusted_web` в trusted-факты.
- **TTL и забывание**: `lastSeenAt` + `ttl`, иначе память деградирует в свалку.
- **Конфликты**: пользователь сказал X, потом Y → нужна стратегия (последний побеждает +
  запись в `supersededBy`, а не молчаливая перезапись).
- **delete / export / retention**: продукт-требование, а не деталь. Компаньон хранит
  личную и бизнес-информацию. Нужны `alteri_one memory list/export/forget`, и явная
  политика хранения. Сейчас в плане этого нет вообще.

---

## 8. ИЗМЕНЕНИЯ: reasoning loop (§8) — переписать

**Дефекты текущего псевдокода (все семь — реальные):**

1. `if (!state.timedOut) state.tick(...)` — при истёкшем дедлайне цикл **продолжает работать**; `break` отсутствует.
2. Нет лимита итераций. `state.done` определяется моделью → цикл инструментов может не закончиться, выжигая токены и деньги.
3. `state.messages >= profile.memory.compaction.trigger` — **смешение единиц**: слева количество сообщений, справа порог в токенах (12000). Типовая и логическая ошибка.
4. `provider.chat(ctx, state.messages)` не совпадает с интерфейсом §6 (`messages` и `model` — required named) → не компилируется.
5. Отказ пользователя на одном шаге **убивает весь прогон** (`return state.aborted`). Правильное поведение: вернуть модели результат «user declined» и дать ей выбрать альтернативу.
6. Нет отмены, нет бюджета, нет детектора застоя (один и тот же tool с одними и теми же аргументами N раз).
7. Независимые таймауты складываются: `modelTimeout` + 60s на каждый из N инструментов могут превысить `globalDeadline`. Нужен **Deadline, который распространяется вниз**, с `min(perCall, remaining)`.

Также рассинхрон: в примере §4 `"timeout": 3000` (3 с на LLM-вызов — нереально мало) против
§5.2 `toolTimeout: 60000`. Привести к одному набору значений (§5.2 выше).

**Новая версия:**

```dart
Future<AlteriOneRunResult> run(AlteriOneRunRequest req, {required CancelToken cancel}) async {
  final deadline = Deadline(startedAt: clock.now(), limit: profile.budgets.deadline);
  final budget   = CostBudget(
      maxUsd: profile.budgets.maxCostUsdPerRun,
      maxTokens: profile.budgets.maxTokensPerRun);

  while (true) {
    if (cancel.isCancelled)   return state.finish(Failed(Cancelled()));
    if (deadline.isExpired)   return state.finish(Failed(Timeout(remaining: Duration.zero)));
    if (budget.isExhausted)   return state.finish(Failed(BudgetExceeded(spent: budget.spent)));
    if (state.steps >= profile.budgets.maxSteps)
                            return state.finish(Failed(StepLimit(steps: state.steps)));
    if (await state.isStagnant(profile.budgets.stagnationWindow))
                            return state.finish(Stopped(Stagnant(repeat: state.lastRepeat)));

    final plan = await _model(deadline, budget, cancel);   // стримится, считает usage

    for (final step in plan.steps) {
      if (cancel.isCancelled) return state.finish(Failed(Cancelled()));

      switch (await policy.evaluate(step, profile)) {
        case Denied(:final reason):
          // Не убиваем прогон: сообщаем модели и даём выбрать иное.
          state.record(step, ToolOutcome.denied(reason));
        case NeedsApproval(:final prompt):
          if (await ui.confirm(prompt.redacted())) {
            await _invoke(step, deadline, budget, cancel);
          } else {
            state.record(step, ToolOutcome.userDeclined());   // ← модель увидит и продолжит
          }
        case Allowed():
          await _invoke(step, deadline, budget, cancel);
      }
    }

    if (budget.tokensUsed >= profile.memory.compaction.triggerTokens) {
      await _compact(state, deadline, budget);   // использует ПРОВЕРЕННУЮ usage, не guess
    }
  }
}
```

Ключевые отличия, каждое — из дефекта выше: дедлайн/бюджет/лимит шагов/отмена/застой
стали условиями выхода; единицы токенов согласованы; `Denied`/`declined` возвращаются
модели, а не убивают прогон; ошибка инструмента — это `ToolOutcome`, который модель читает.
`_invoke` внутри применяет retry только для `retryable` ошибок и **никогда** автоматически
не повторяет side-effecting-вызовы без `idempotencyKey` (спека упоминает ключ в `meta`,
но не определяет контракт — и без него ретрай `send_message` отправит сообщение дважды).

---

## 9. УЛУЧШЕНИЯ: трассировка и автотесты (§11)

Спека смешивает три разные вещи под словом «автотест» и требует «проверки качества
loop/memory/persona», но не содержит ни одного инструмента, который это может сделать.

**(а) Нужен детерминированный фейковый провайдер — это отсутствующая задача, блокирующая
всё остальное.** Acceptance 0.9, 1.3, 1.4, 2.1, 2.3 требуют проверки поведения loop,
которое невозможно проверить без него: реальная LLM стоит денег, недетерминирована и
 flaky в CI. Требования:

```dart
abstract interface class FakeProvider implements AlteriOneProvider {
  /// Ответы задаются сценарием: по (шаг, профиль) -> заготовка ответа.
  void script(Map<Object, AlteriOneChatResponse> responses);
  /// Полное дерево вызовов для replay.
  void record();
  List<ChatTurn> transcript();
}
```

Плюс инъектируемые `AlteriOneClock` и генератор id (иначе в логах и trace-файлах
невозможны golden-тесты). Это **Фаза 0**, а не Фаза 1.

**(б) Два уровня тестирования, а не один:**

| Уровень | Что | Модель | CI | Бюджет |
|---|---|---|---|---|
| Tier 1: детерминированные тесты | unit + contract (протокол, парсеры, policy, бюджеты, память, компакция) | фейковая | каждый коммит | 0 |
| Tier 2: eval-набор | качество поведения: помнит ли факт, уважает ли deny, отвечает ли в тоне persona | реальная | вручную/по расписанию | лимит в USD |

Ошибка текущего плана: «автотест-хarness» с критерием «проверяет качество loop»
на реальной модели в CI = медленно, дорого, flakily, и всё равно не воспроизводится.
Tier 2 надо запускать против дешёвой модели и **не** делать gating'ом на первом этапе.

**(в) Replay/транскрипт.** Прогон должен писать пошаговый лог (цель → план → каждый шаг с
аргументами, результатом, токенами, стоимостью, длительностью) и уметь воспроизводиться.
Это дешёвая замена OTel на 90% задач отладки: «почему агент сделал это» не отвечает
трассировка RPC-вызовов. OTel (когда будет реальный пакет) добавляется поверх, а не вместо.

**(г) `alteri_one doctor`.** В специ нет ни одной диагностической команды, а у продукта,
который читает YAML, ходит по сети и запускает модули, она обязательна: валидация всех
конфигов, проба провайдеров и их capabilities, проверка прав, версий, путей, свободного
места, «почему мой модуль не загрузился».

---

## 10. ДОПОЛНЕНИЯ: чего нет вообще

### P0 — до первой строки кода

| # | Дополнение | Зачем |
|---|---|---|
| 1 | `AlteriOneClock` + генератор id + `FakeProvider` | Без них ни один acceptance из Фазы 0–2 не тестируется |
| 2 | `Deadline`, `CancelToken`, `CostBudget` | Time-boxing из принципа №3 без них декларативен |
| 3 | Таксономия ошибок (таблица §4) | Retry/degrade без неё — случайное поведение |
| 4 | `apiVersion` + миграции конфигов + `doctor` | Пользовательские данные без версии ломаются при первом же релизе |
| 5 | Handshake `core.initialize` + semver-политика | Нет маркетплейса без этого |
| 6 | ADR (architecture decision records) | 6+ необращённых развилок уже в спеке; через месяц никто не вспомнит, почему |
| 7 | CI: `dart analyze --fatal-infos`, `dart test`, format-check, matrix Linux/macOS/Windows | Принцип «Done = acceptance пройдена автоматически» без CI декларативен |
| 8 | Решение по web-таргету (см. §12) | Сейчас он тихо противоречит §15.3 |
| 9 | Threat model (lethal trifecta, provenance) | В §17 один принцип без дизайна |
| 10 | `.gitignore`, `dart_test.yaml` (таймауты), coverage-конфиг | Мелочи, но без них «autotest-core» не собрать |

### P1 — до релиза v1

| # | Дополнение | Зачем |
|---|---|---|
| 11 | Tool-result budgeting: обрезка/выгрузка больших результатов в артефакт + указатель | **Главная причина раздувания контекста** в реальных агентах. Компакция — дорогой ответ; дешёвый — бюджет на границе инструмента |
| 12 | Политика версий и деградации capability-модулей | Манифест без неё — источник тихих поломок |
| 13 | Транскрипт + replay + `why`-команда | Отладка поведения, а не вызовов |
| 14 | Feedback-loop: 👍/👎 + «это было неверно» → в eval-набор | Без обратной связи evals деградируют от дефолта |
| 15 | `intl` с Фазы 0 | В конфиге уже `language: ru`; строки разъедутся поздно и дорого |
| 16 | Структурированные логи + редакция секретов/приватных данных | Компаньон логирует личные данные; trace ≠ приватный |
| 17 | Exit codes + `--json`/`--headless`/`--dry-run` | Скриптуемость и CI; `--dry-run` упомянут в 3.2, но не определён |
| 18 | Генератор модуля: `alteri_one init module <name>` (или `dart create -t`) | «Как добавить модуль» — основной цикл роста OSS; руками не пишут |
| 19 | memory export/forget/retention | Приватность как функция продукта |
| 20 | SHA-256 контента/профиля/транскрипта + `doctor --verify` | Воспроизводимость и отладка |
| 21 | Graceful shutdown: SIGINT → cancel → drain → flush state → код выхода | Терминальный продукт без этого теряет данные на Ctrl-C |
| 22 | `SECURITY.md`, `CODE_OF_CONDUCT`, `CONTRIBUTING`, `CODEOWNERS` | Для проекта с marketplace это минимум; SECURITY.md — до, а не после Tier 2 |
| 23 | Релиз: `melos version`, coordinated versioning по DAG, changelog, бинари под 3 ОС, notarization/подпись, `dart pub publish --dry-run` | Публикуемые пакеты не должны иметь path-зависимостей — проверяется только в момент публикации |

### P2 — после v1

| # | Дополнение | Зачем |
|---|---|---|
| 24 | Бюджет, глубина, конкурентность и каскадная отмена у subagents | Рекурсивная делегация без общего бюджета = размножение токенов |
| 25 | Дешёвая модель для subagents по умолчанию | Самый дешёвый рычаг стоимости, в спеке не упомянут |
| 26 | Failover + circuit breaker между провайдерами | Принцип №4 без механики |
| 27 | Prompt caching (где поддержан) | Прямое снижение стоимости длинного системного контекста |
| 28 | OTel поверх транскриптов | Когда появится реальный пакет |
| 29 | Прецеденты конфигурации (5 уровней) | Сейчас прецедент не задан нигде |
| 30 | Параллельные профили / многопользовательский режим | Не заявлен, но «бизнес»-профиль намекает |

---

## 11. ОПТИМИЗАЦИЯ: план и объём

### 11.1 Главное: песочница выходит из Фазы 0

Текущий план ставит OS-песочницу произвольного Dart-кода **в Фазу 0 как gate**. Это
наиболее исследовательский, наиболее платформенно-зависимый и наиболее вероятно
недооценённый компонент во всём проекте (bwrap/nsjail, cgroups, seccomp, три платформы,
fail-closed политика, adversarial-тесты). Поставить его первым — значит рисковать всем
проектом ради компонента, который не нужен для демонстрации ядра.

Предлагаемая переработка порядка: **marketplace начинается с Tier 0 (skill-паки — данные,
без кода, без песочницы), Tier 2 появляется позже, когда продукт уже полезен.**

### 11.2 Новый порядок фаз

| Фаза | Содержание | Почему так |
|---|---|---|
| **0. Walking skeleton** | monorepo по §2.1, CI, ADR, `protocol` (конверт+фрейминг+ошибки), in-process + stdio транспорт, **`FakeProvider`+`Clock`**, profile-схема с `apiVersion`, `provider` (стриминг+usage+probe), engine с deadline/budget/cancel/maxSteps, **минимальный CLI REPL** (§15: первый фронтенд — это CLI), Tier-1 тесты, `doctor`, constitution | Вертикальный срез работает **в Фазе 0**, а не в Фазе 1. Проверяет протокол, профиль, loop и транспорт на одном примере. CLI поднят сюда, потому что это самый дешёвый способ увидеть, что ядро вообще работает |
| **1. Память и политика** | `platform` (storage/http/clock/paths) + `hive_ce`, типизированные `MemoryRecord` с provenance/TTL, compaction (тестируется на фейке), policy engine `deny>confirm>allow`, один trusted-модуль, tool-result budgeting | Память и политика — то, что делает ядро «личным», а не «чатботом». Обе тестируются детерминированно |
| **2. Skill-паки и MCP-клиент** | формат skill-пака по Agent Skills spec, provenance-метки и границы недоверенного контента, MCP **client** (`dart_mcp`/`mcp_dart`, ревизия `2026-07-28`) | **Marketplace становится возможен** — без единой строки песочницы. Самый быстрый путь к ценности |
| **3. Недоверенные модули** | out-of-process launcher, scrubbed env, Linux bwrap/nsjail + cgroup + seccomp, брокеры (secret/network), adversarial-набор тестов, политика macOS/Windows = fail-closed | Песочница здесь, когда её ценность уже доказана продуктом |
| **4. Автономность** | subagents с бюджетом/глубиной/конкурентностью, `ReasoningStrategy` (ReAct → plan-execute), developer-режим, MCP **server mode** | Автономия опаснее всего на недоверенных capability; логично после песочницы |
| **5. SDK и фронтенды** | `alteri_one_sdk`, `init module`-генератор, CLI polish, Flutter app, web | Embedding и GUI — про дистрибуцию |
| **6. Экосистема и релиз** | marketplace, docs, OTel, `melos version`/changelog/бинари/подпись, CI-релиз, `SECURITY.md` | Релизная инфраструктура |

Кривые роста — те же по духу, но **проверяемые**: «вертикальный срез зелёный на фейке»,
«marketplace: skill-пак ставится и применяется без изменения ядра», «adversarial-набор
проходит, ядро выживает».

### 11.3 Грамотные acceptance-критерии

Спека объявляет «Done = acceptance пройдена автоматически (test/автотест)» и сама же
нарушает это девять раз: «README открыт», «структура диаграммы core», «CLI — usable
компаньон в терминале», «автономный developer mode работает на репозитории».

Предлагаемая грамматика на весь план:

```
Acceptance: <команда> завершается с кодом 0 и проверяет <свойство>.
  test/…  — имя конкретного теста
  где нет автоматической проверки — критерий переносится в кривые роста (человек),
  а не в задачу.
```

И переименовать «автотест» в четыре разных слова: **unit / contract / integration / eval** —
сейчас ими подменены все четыре.

### 11.4 Что убрать, чтобы проект взлетел

| Кандидат | Обоснование |
|---|---|
| `dart:ffi` + локальные модели (§18) | В §18 перечислено как фича, но **задачи нет ни в одной фазе**. Это отдельный продукт (llama.cpp/GGUF-биндинги). «Model-agnostic» уже покрыт локальным OpenAI-совместимым сервером из §6 |
| Векторный recall из v1 | Нет ANN в Hive, кандидаты незрелые/нативные. Интерфейс `VectorIndex` — и достаточно |
| `plan-execute` / `recursive` из Фазы 2.2 | `ReasoningStrategy` как интерфейс + одна реализация ReAct. Вторая и третья стратегии без реального use case — это отладка комбинационного взрыва |
| OTel в Фаза 4.3 как «позже» | Транскрипт + traceId + JSONL дают 90% ценности за 1% усилий. OTel — когда появится пакет, и **поверх** транскрипта |
| `cli_pkg` | Grinder-релизы. Для нового CLI — `dart build cli` / `dart install` |
| 11 пакетов на старте | `protocol`, `platform`, `core`, `cli`, `memory`, `skills` — 6. `providers`, `mcp`, `subagents`, `hooks`, `tracing`, `sandbox`, `sdk` добавляются, **когда появляется реальное дублирование**, а не заранее. Стоимость bootstrap/CI/churn в фазе 0 — реальный риск |
| web как «monolith» по умолчанию | Требует платформенного слоя + web-хранилища + отказа от изолятов. Обсуждается ниже |
| `hive_adapters`, `open-telemetry`, `otlp_client`, `pubspec.workspaces.yaml` | Не существует |

### 11.5 §1.1 — позиционирование и north-star (в спеку)

Спека описывает только механизм и не отвечает на вопрос «зачем это, если есть Claude Code
и ChatGPT». Стоит зафиксировать явно, с тремя измеримыми отличиями:

1. **Локальность по умолчанию.** Один AOT-бинарь, OpenAI-совместимый wire, локальный
   сервер как обычный провайдер → 0 телеметрии по умолчанию, работа офлайн. North-star:
   `alteri_one` полностью функционален без единого внешнего вызова.
2. **Embeddable SDK.** Ядро как библиотека, а не как приложение. North-star: внешний
   проект запускает loop через `sdk` не форкая core.
3. **Один core — три личности** (companion/business/developer) с переключением профиля
   и раздельной памятью, вместо трёх отдельных чатов с тремя историями.

Измеримые цели, которые стоит зафиксировать в README: холодный старт < X мс (AOT),
100% офлайн-работа при локальной модели, 0 байт телеметрии без явного согласия,
время до первого полезного ответа в CLI.

---

## 12. РАЗРЕШЕНИЕ открытых вопросов (§15)

| # | Вопрос в спеке | Ответ |
|---|---|---|
| 1 | Melos vs pub workspaces, совместимость с 3.13.4 | Оба: pub workspaces (Dart ≥3.6) связывают пакеты, melos 8.9.0 оркестрирует скрипты/версии/релиз. Глобы в `workspace:` — Dart ≥3.11, у нас 3.13. Конфиг melos — в корневом `pubspec.yaml` |
| 2 | Flutter для app + web | Да, Flutter. `provider`/`rx` — не критично, состояние можно держать в ядре (поток) + тонком UI; не выбирать DI-фреймворк до Фазы 5 |
| 3 | Web: monolith или тонкий фронт | **Решено неверно.** Monolith возможен только при полном отсутствии `dart:io` в ядре, что означает `platform`-слой, web-хранилище, отказ от изолятов **и** от Tier 2. Рекомендация: **v1 — только нативный CLI**; web в Фазе 5, и на старте решить: полный monolith (нужен web-impl хранилища, напр. IndexedDB) либо тонкий UI поверх удалённого/встроенного core. Записать это явным «решено», а не оставлять открытым под уже принятым решением |
| 4 | Hive: схема коллекций | `hive_ce`; коллекции: `sessions`, `messages`, `facts`, `episodes`, `preferences`, `artifacts`. Вектор — за `VectorIndex`, вне v1 (§7) |
| 5 | Sandbox: isolate + limits + allowlist, «OK?» | **Нет.** Заменяется на три тира исполнения (§3.2). Isolate = локализация ошибок, не безопасность |
| 6 | Tracing | Транскрипт + `traceId` + JSONL в Фазе 0; OTel — Фаза 6, реальный пакет (`opentelemetry` — Beta, community) |

---

## 13. Конституция (§17) — переписать 2 принципа, добавить 4

Существующие 6 в целом хороши; правки:

- **№1 «Core is dumb»** противоречит §8, где в ядре живёт сам loop. Переформулировать:
  **«Ядро владеет движком; capability-пакеты владеют миром.»** Ядро не знает про скиллы,
  календари и почту — но владеет дедлайнами, бюджетами, политикой и протоколом.
- **№2 «One envelope, everywhere»** неизбежно нарушается: OTel-спаны (W3C-контекст),
  wire провайдера (OpenAI), MCP (диалект 2026-07-28), UX-подтверждения, файловые
  артефакты. Как конституционный принцип он обесценивается первым же нарушением.
  Переформулировать: **«Один конверт — на границе модуль↔ядро. На каждой внешней границе —
  адаптер.»**
- **№3 «Total time-boxing»** — добавить «и всегда с путём отмены и бюджетом, а не только таймаутом».
- **№4 «Fail soft, recover loud»** — добавить «деградация только по явной политике; неудачная
  изоляция → отказ, а не ослабление режима».

Новые принципы:

7. **Determinism where it matters.** Всё, что можно, внедряется: время, id, провайдер.
   Поведение, которое нельзя воспроизвести, нельзя и починить.
8. **Cost is a resource, not a footnote.** Любой прогон имеет бюджет токенов и денег и
   умеет их исчерпать. «Бесплатного» прогона не бывает.
9. **Untrusted by default.** Вывод любого инструмента, MCP-сервера и веб-страницы —
   недоверенный контент с provenance-меткой. Он информирует, но не распоряжается.
10. **Configuration is data, therefore versioned.** YAML имеет `apiVersion`, миграции и
   диагностику. Пользователь не должен гадать, почему профиль не загрузился.

---

## 14. Приоритет действий

**Немедленно (до строки кода):**
1. Принять решение по §12.3 (web-таргет) — от него зависит граф пакетов.
2. Принять трёхтировую модель исполнения вместо §3.5 и перенести песочницу из Фазы 0.
3. Принять переработку фаз из §11.2.
4. Починить §2 (melos 8), §5 (YAML + `apiVersion`), §6/§8 (интерфейс), §18 (список фич).
5. Добавить в Фазу 0: `FakeProvider` + `Clock`, `Deadline`/`CancelToken`/`CostBudget`,
   таксономию ошибок, handshake, ADR, CI, `doctor`.

**Первые коммиты после этого:**
6. `protocol` с фреймингом, лимитами, sealed union, отменой и таблицей ошибок.
7. `platform` с `Clock`/`Paths`/`Http`/`Storage`/`Concurrency` — чтобы детерминизм был
   конструктивным, а не дисциплиной.
8. `FakeProvider` и один end-to-end тест: goal → plan → tool → результат → finish.

**Убрать из скоупа:** FFI/локальные модели, вектор в v1, `plan-execute`/`recursive` в v1,
OTel в v1, web в v1, `cli_pkg`, 11 пакетов на старте.

---

## 15. Источники

Dart 3.13 / SDK
- <https://dart.dev/blog/announcing-dart-3-13> · <https://dart.dev/language/primary-constructors>
- <https://dart.dev/language/dot-shorthands> · <https://dart.dev/language/collections#null-aware-element>
- <https://dart.dev/language/patterns> · <https://dart.dev/tools/pub/workspaces>
- <https://dart.dev/tools/dart-compile#exe> · <https://dart.dev/tools/cli-distribution>
- <https://dart.dev/libraries> · <https://dart.dev/language/concurrency#limitations-of-isolates>

Пакеты
- <https://pub.dev/packages/melos> · <https://melos.invertase.dev/getting-started>
- <https://pub.dev/packages/hive> (SDK `<3.0.0`) · <https://pub.dev/packages/hive_ce> · <https://pub.dev/packages/hive_ce_generator>
- <https://pub.dev/packages/freezed> (нужен 4.x) · <https://pub.dev/packages/json_serializable> · <https://pub.dev/packages/build_runner>
- <https://pub.dev/packages/opentelemetry> · <https://pub.dev/packages/dartastic_opentelemetry>
- <https://pub.dev/packages/dart_mcp> (official, experimental) · <https://pub.dev/packages/mcp_dart>
- <https://pub.dev/packages/args> · <https://pub.dev/packages/local_hnsw> · <https://pub.dev/packages/sqlite3>

MCP
- <https://modelcontextprotocol.io/specification/2026-07-28> · <https://github.com/modelcontextprotocol/modelcontextprotocol/releases/tag/2026-07-28>
- <https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices>

Изоляция и безопасность
- <https://api.dart.dev/dart-io/Platform/environment.html> · <https://api.dart.dev/dart-io/exit.html>
- <https://api.dart.dev/dart-ffi/DynamicLibrary/DynamicLibrary/open.html>
- <https://api.dart.dev/dart-developer/Service/getInfo.html> · <https://github.com/dart-lang/sdk/issues/36575>
- <https://github.com/dart-lang/sdk/issues/10530> (динамическая загрузка) · <https://github.com/dart-lang/sdk/issues/53884> (Wasm)
- <https://github.com/containers/bubblewrap> · <https://github.com/google/nsjail> · <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- <https://www.w3.org/TR/trace-context/> (для принципа №2)

Prompt injection
- <https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/> · <https://arxiv.org/abs/2503.18813> (CaMeL)
- <https://arxiv.org/abs/2506.08837> (design patterns) · <https://genai.owasp.org/llmrisk/llm01-prompt-injection/>
- <https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks>
