# AlteriOne — Техническое задание и рабочая спецификация (core)

> Документ-якорь для разработки ядра AlteriOne. Фиксирует архитектурные решения, протокол,
> модель исполнения и разбивку на задачи с машинопроверяемыми критериями готовности.
> Рабочий документ — обновляйте по мере принятия решений.
>
> **Лицензия:** MIT. **Бренд:** `AlteriOne` (PascalCase).
> **Пакеты workspace:** `alteri_one_*`. **Публичный пакет для embedders:** `alteri_one_sdk`.
>
> **Область v1:** нативный CLI. Flutter app и web — Фаза 5. OS-песочница недоверенных
> модулей (Tier 2) — Фаза 3; до неё доступны только Tier 0 (skill-паки) и Tier 1
> (доверенные модули в процессе).
>
> Ключевые проектные решения и их расположение в документе сведены в §20.2.
> Все внешние факты (версии SDK и пакетов, ревизии протоколов, возможности рантайма)
> проверены по источникам из §20.3.

## 1. Обзор и принятые решения

- **Назначение.** AlteriOne — open-source MIT-ядро для локально исполняемого LLM-агента. Модель, endpoint и набор capability не зашиты в ядро; они выбираются профилем и проверяются capability-пробой.
- **Язык и сборка.** Базовый toolchain — Dart 3.13.4. Core — чистый Dart, без Flutter; публичные пакеты используют ограничение `^3.13.0`. v1 собирается как нативный AOT CLI, без JIT и runtime reflection. Flutter app и web вынесены за пределы v1 (Фаза 5).
- **Граница платформы.** `alteri_one_core` — чистый Dart и не импортирует `dart:io` напрямую. Все операции с файлами, сетью, часами, путями, процессами и конкурентностью проходят через `alteri_one_platform` с conditional imports `dart:io | package:web`.
- **Workspace.** Используется Melos 8.9.0 и pub workspaces: конфигурация находится в корневом `pubspec.yaml` в секциях `workspace:` и `melos:`. `melos.yaml` и `pubspec.workspaces.yaml` не создаются; `pubspec.lock` коммитится.
- **Хранилище.** Вместо `hive`, несовместимого с Dart 3, используется `hive_ce` 2.20.0 с `hive_ce_generator`. Векторный recall скрыт за интерфейсом `VectorIndex`; его реализация не входит в v1.
- **Wire провайдера.** Единый внешний wire — OpenAI-compatible chat completions. Локальный OpenAI-compatible server является обычным provider; model-agnostic означает наличие capability-матрицы, а не одинаковый набор функций у всех endpoint. Direct FFI/GGUF binding не входит в v1.
- **Протокольная граница.** Между ядром и модулями используется JSON-RPC 2.0 с LSP-style фреймингом, negotiation и типизированным sealed union конвертов. `proto` описывает версию конверта, `moduleVersion` — semver манифеста модуля.
- **Исполнение и загрузка кода.** Tier 0 — декларативный Skill Pack без кода и прав; Tier 1 — Trusted Module, линкуемый в AOT-бинарь; Tier 2 — Untrusted Module, отдельный AOT-процесс под OS sandbox. Dart не загружает классы из произвольных файлов в runtime: «dynamic import» отсутствует; Trusted-модули регистрируются codegen-регистром на этапе сборки, Untrusted-модули запускаются только out-of-process. Изолят в Tier 1 локализует ошибки и разделяет работу, но не создаёт границу безопасности.
- **Конфигурация и безопасность.** Встроенные дефолты являются Dart-объектами в бинаре; YAML имеет `apiVersion` и `kind`, валидируется кодом и проверяется `alteri_one doctor --validate-config`. Политика имеет порядок `deny > confirm > allow`; манифест декларирует capability, а enforcement вычисляется как пересечение политик. Подпись подтверждает происхождение, но не безопасность.
- **Границы v1 и совместимость.** v1 включает шесть пакетов: `alteri_one_protocol`, `alteri_one_platform`, `alteri_one_core`, `alteri_one_cli`, `alteri_one_memory`, `alteri_one_skills`. MCP не считается бесплатной интероперабельностью с JSON-RPC: для него нужен отдельный dialect adapter; проверки различают `unit`, `contract`, `integration` и `eval`.

### 1.1. Позиционирование и north-star

AlteriOne отличается от облачных чат-агентов не идентичностью модели, а исполнением и архитектурой:

- **Локальность и офлайн.** AOT-бинарь, локальное состояние и OpenAI-compatible server позволяют выполнять основной сценарий без внешнего вызова. Сетевой доступ к облачному provider остаётся конфигурируемой возможностью, а не обязательным условием.
- **Embeddable core.** Ядро остаётся библиотекой, а не только приложением: внешний проект запускает тот же loop через публичный SDK без форка внутреннего core.
- **Один core — три личности.** `companion`, `business` и `developer` используют один движок и раздельные данные профилей, памяти и политик; переключение не создаёт три независимых чата с разной реализацией.

North-star измеряется тремя проверяемыми целями:

1. AOT CLI на эталонной нативной платформе достигает `p95` холодного старта до приглашения ввода не более **250 мс**; измеряется отдельным benchmark-прогоном с фиксированными OS, CPU и AOT build.
2. Offline-набор end-to-end сценариев проходит на **100%** при локальном OpenAI-compatible provider и заблокированном внешнем egress; любая попытка внешнего сетевого вызова считается ошибкой.
3. В сборке без явного opt-in отправляется **0 байт** телеметрии (проверяется network capture/audit); сетевые запросы учитываются только для явно настроенных provider и capability broker.

## 2. Структура monorepo

### 2.1. Состав workspace

```text
alteri_one/
├── pubspec.yaml                    # workspace + melos; единственный конфиг Melos
├── pubspec.lock                    # фиксированные версии, коммитится
├── analysis_options.yaml
├── README.md
├── LICENSE                         # MIT
├── packages/
│   ├── alteri_one_protocol/        # envelope, framing, codec, ошибки
│   ├── alteri_one_platform/         # Storage, Http, Clock, Paths, Concurrency, ProcessHost
│   ├── alteri_one_core/             # loop, registry, bus, policy, budget
│   ├── alteri_one_memory/           # hive_ce persistence и типизированные записи
│   └── alteri_one_skills/           # Tier 0 Skill Pack и их загрузчик
├── applications/
│   └── cli/                         # package: alteri_one_cli; нативный CLI v1
├── sdk/                             # зарезервировано для alteri_one_sdk
└── config/                          # только fixtures для тестов и примеров
    └── fixtures/
        ├── profiles/
        ├── modules/
        └── policies/
```

`sdk/` не содержит рабочего v1-пакета: публичный pub.dev-пакет для внешних embedders называется `alteri_one_sdk` и появляется после стабилизации API. Все workspace-пакеты, включая приложение, используют префикс `alteri_one_`; имя `alteri_one` без суффикса не является именем пакета. Корневой `alteri_one_workspace` — контейнер workspace и не входит в список шести v1-пакетов.

Корневой `pubspec.yaml`:

```yaml
name: alteri_one_workspace
publish_to: none

environment:
  sdk: ^3.13.0

workspace:
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
    generate: 'melos exec -c 1 --depends-on="^build" -- dart run build_runner build'
    aot: melos exec -c 1 --scope="alteri_one_cli" -- dart build cli
    doctor: melos exec -c 1 --scope="alteri_one_cli" -- dart run bin/main.dart doctor --validate-config
```

Toolchain CI фиксируется на Dart 3.13.4. Pub workspaces связывают локальные пакеты без отдельного `pubspec.workspaces.yaml`; `melos bootstrap` не является обязательным шагом линковки и остаётся только операцией оркестрации скриптов и версий. Парсинг CLI использует `args: ^2.7.0`; дистрибуция AOT выполняется через `dart build cli`.

Пример минимального workspace-пакета:

```yaml
name: alteri_one_protocol
publish_to: none

resolution: workspace

environment:
  sdk: ^3.13.0
```

Поле `resolution: workspace` обязательно в каждом пакете workspace. `pubspec.lock` хранится в корне и обновляется при изменении dependency graph.

### 2.2. Пакеты v1 и отложенные пакеты

В v1 ровно шесть пакетов. Дополнительный пакет не создаётся без повторяемой границы или конкретного дублирования кода.

| Пакет | Статус | Роль |
|---|---|---|
| `alteri_one_protocol` | v1 | JSON-RPC 2.0 envelope, sealed union, framing, negotiation, error taxonomy |
| `alteri_one_platform` | v1 | Conditional implementations `dart:io` и `package:web`; `Storage`, `Http`, `Clock`, `Paths`, `Concurrency`, `ProcessHost` |
| `alteri_one_core` | v1 | Движок, capability registry, event bus, policy, deadline, budget, cancellation |
| `alteri_one_cli` | v1 | Нативный CLI, composition root и пользовательский ввод/вывод |
| `alteri_one_memory` | v1 | `hive_ce` persistence, типизированные записи памяти и compaction |
| `alteri_one_skills` | v1 | Tier 0 Skill Pack: данные, prompts, ресурсы, provenance и загрузка без исполнения кода |
| `alteri_one_providers` | отложен | Выделяется при появлении второго независимого provider implementation или реального дублирования wire-логики |
| `alteri_one_mcp` | отложен | Отдельный MCP client/server adapter; кандидаты — `dart_mcp` 0.5.2 или `mcp_dart` 2.4.2 |
| `alteri_one_subagents` | отложен | Рекурсивная делегация с отдельным budget, глубиной и cancellation |
| `alteri_one_tracing` | отложен | Расширение поверх transcript/traceId; OTel не входит в v1 |
| `alteri_one_sandbox` | отложен | Host-инфраструктура Tier 2; OS sandbox появляется вместе с marketplace для кода |
| `alteri_one_hooks` | отложен | Выделяется позже; подтверждения и ограничения входят в policy, наблюдения — в notifications |
| `alteri_one_sdk` | отложен | Публичный embedding API; имя зарезервировано для будущего pub.dev-пакета |

В v1 OpenAI-compatible adapter остаётся частью core/composition boundary; `alteri_one_providers` не создаётся до появления реального дублирования. Аналогично, `hooks` остаются policy и notifications, а не отдельным пакетом.

### 2.3. Правила зависимостей

Граф зависимостей направлен от инфраструктуры к capability и composition root. Циклы запрещены.

| Пакет | Разрешённые прямые зависимости | Запрещённые зависимости и инварианты |
|---|---|---|
| `alteri_one_protocol` | Только `dart:core` и Dart/3-совместимые pure-Dart библиотеки | Нет `dart:io`, `dart:mirrors`, `dart:ffi` и platform-пакетов |
| `alteri_one_platform` | Conditional imports `dart:io` и `package:web`, `alteri_one_protocol` при необходимости | Не содержит domain-логики и не зависит от core |
| `alteri_one_core` | `alteri_one_protocol`, `alteri_one_platform` | Не импортирует `dart:io` напрямую и не зависит от `alteri_one_sandbox` |
| `alteri_one_memory` | `alteri_one_core`, `alteri_one_platform`, `hive_ce` и generator | Не реализует provider или UI |
| `alteri_one_skills` | `alteri_one_core`, `alteri_one_protocol` | Не исполняет код Skill Pack и не выдаёт capability в обход policy |
| `alteri_one_cli` | `alteri_one_core`, `alteri_one_platform`, `alteri_one_protocol`, подключаемые memory/skills; `alteri_one_sandbox` при включении Tier 2 | CLI не становится зависимостью core |
| `alteri_one_sandbox` (отложен) | `alteri_one_platform`, `alteri_one_protocol` и OS-specific host adapter | **Не зависит от `alteri_one_core` и не импортируется им** |
| `alteri_one_sdk` (отложен) | Только стабилизированные публичные API и необходимые capability-пакеты | Не раскрывает внутренние registry и storage implementation |

`alteri_one_sandbox` подключается composition root'ом (например, CLI) при включении Tier 2. Core не знает о конкретном OS sandbox и получает только типизированный host interface. Прямой `dart:io` в core/protocol запрещён; web-реализация `alteri_one_platform` не меняет этот инвариант.

### 2.4. Почему `config/` в репозитории не является рантайм-конфигом

AOT-бинарь не зависит от файлов рядом с исходниками. Каталог `config/` содержит только fixtures для unit/contract/integration/eval и примеры документации; он не включается в путь поиска при запуске. Тест или `doctor` может указать fixture явно, но неявный fallback на `config/` запрещён.

| Приоритет | Уровень | Источник | Роль |
|---:|---:|---|---|
| 0 | Встроенные дефолты | Dart-объекты в бинаре | Базовые значения, не требующие YAML в runtime |
| 1 | Пользовательский | `~/.alteri_one/` | `profiles/`, `policies.d/`, `modules/`, `state/` и локальные настройки |
| 2 | Проектный | `./.alteri_one/project.yaml` | Параметры репозитория, developer-профиль, команды и тестовые fixtures |
| 3 | CLI | Флаги командной строки | Локальное переопределение для одного запуска |

Уровни разрешаются от 0 к 3; уровень с большим приоритетом побеждает при конфликте. Подробные правила слияния и четыре уровня повторно фиксируются в §5.4.

## 3. Модульная система

### 3.1. Контракт модуля

Контракт — sealed, версионированный и типизированный. Произвольный `Map<String, dynamic>` не является валидным представлением capability, параметров или результата. JSON-кодеки генерируются через `freezed` 4.0.2, `json_serializable` 6.14.1 и `build_runner` 2.16.1; reflection и runtime-десериализация типов не используются.

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'module_contract.freezed.dart';
part 'module_contract.g.dart';

@freezed
sealed class ModuleManifest with _$ModuleManifest {
  const factory ModuleManifest({
    required String apiVersion,
    required String kind,
    required String name,
    required String moduleVersion,
    required ModuleTier tier,
    required String entrypoint,
    required ProtocolRange protocol,
    String? description,
    required List<CapabilityDeclaration> capabilities,
    required List<ModuleDependency> dependencies,
  }) = _ModuleManifest;
  const ModuleManifest._();
}

@freezed
sealed class ModuleParams with _$ModuleParams {
  const factory ModuleParams.search({
    required String query,
    @Default(10) int limit,
  }) = SearchParams;
}

abstract interface class AlteriOneModule {
  ModuleManifest get manifest;

  Future<void> start(AlteriOneRuntime runtime);

  Future<void> stop();

  Stream<AlteriOneEvent> get events;

  Future<AlteriOneResult> handle(ModuleParams params);
}
```

`apiVersion`, `kind`, `name`, `moduleVersion`, protocol range и состав capability проверяются кодом до запуска. Неизвестные поля, отсутствующие обязательные поля, несовместимый `apiVersion` и нарушение semver-контракта являются ошибкой валидации, а не предупреждением. Tier 1 реализует локальный интерфейс; Tier 2 реализует тот же контракт через процессный адаптер и не импортируется в VM ядра. Tier 0 не реализует `AlteriOneModule`: Skill Pack остаётся данными.

### 3.2. Lifecycle без runtime-загрузки кода

Общая последовательность:

```text
discover → validate → bind → initialize → start → serve → stop
```

1. **Discover.** Trusted-реализации берутся из сгенерированного registry; Tier 0 — из зарегистрированных Skill Pack; Tier 2 — из подписанного registry, содержащего digest и ссылку на precompiled AOT executable.
2. **Validate.** Проверяются `apiVersion`, `kind`, `moduleVersion`, dependency constraints, capability declarations, policy intersection и допустимые transport limits. Подпись проверяет происхождение артефакта, но не обещает безопасное поведение.
3. **Bind.** Capability ID связывается с конкретной реализацией и trust tier; конфликт ID или неоднозначное разрешение останавливает запуск.
4. **Initialize.** Для Tier 1 создаётся объект из codegen-registry. Для Tier 2 сначала проверяется подпись, затем создаётся отдельный процесс в OS sandbox с `includeParentEnvironment: false`, изолированным tmpfs workspace и выполняется `core.initialize`; capability не публикуется до `accepted: true`.
5. **Start.** После успешного handshake модуль получает runtime только в пределах объявленных и разрешённых capability. Tier 2 запускается с минимальным окружением и capability broker.
6. **Serve/stop.** Запросы обслуживаются только после `start`; `stop` идемпотентен, а ошибка Tier 1 изолируется только настолько, насколько позволяет изолят.

В Dart нет загрузчика классов для подключения произвольного кода в работающую VM. `Isolate.spawnUri` остаётся same-process механизмом и не используется для Tier 2. Поэтому выражения вроде `dynamic import`, runtime-сканирование Dart-файлов и исполнение кода из manifest не являются частью lifecycle.

### 3.3. Star-topology и хаб

`AlteriOneCore` — единственный hub и владелец engine loop, deadline, budget, policy и registry. Модули не соединяются напрямую: запрос проходит через core, адресуется namespaced-методом и возвращается через тот же envelope. Core может маршрутизировать один capability-запрос к другому модулю, но не передаёт модулю внутренние ссылки на storage, provider или policy engine.

События идут в одном event bus с `traceId`; подписка Tier 0 ограничена переданным контекстом. Повтор запроса с побочным эффектом допускается только при наличии `idempotencyKey`; transport не превращает изолят или IPC в границу доверия.

### 3.4. Registry, разрешение версий и semver-политика

Registry хранит immutable descriptor capability, trust tier, manifest digest, protocol range, transport limits и ссылку на реализацию. Источники имеют разные типы записей, но общий resolver.

| Тип записи | Источник | Способ привязки |
|---|---|---|
| Trusted capability | Сгенерированный registry | Символ Dart, известный на этапе сборки |
| Skill Pack | Пользовательский или проектный каталог | Стабильный capability ID и версия данных |
| Untrusted capability | Подписанный registry | Digest и precompiled AOT path; путь не берётся из YAML |

Resolver выполняет следующие проверки:

- сначала сопоставляет точный capability ID, затем проверяет semver-constraint каждой зависимости;
- выбирает максимальную совместимую версию protocol из диапазона, без неявного перехода на `latest`;
- не допускает двух реализаций одного capability с неявным приоритетом; конфликт завершает bind;
- принимает prerelease-версии только по явно заданному каналу или флагу, а marketplace по умолчанию допускает stable semver;
- различает `proto` версии конверта и `moduleVersion` манифеста: первая определяет wire-совместимость, вторая — совместимость реализации и capability;
- при несовпадении версий возвращает negotiation error и не выполняет неоговорённый downgrade.

Подпись artifact и проверка digest отвечают за происхождение и целостность. Поведение остаётся предметом policy, capability-проверок и sandbox.

### 3.5. Три тира исполнения

| Тир | Что это | Как исполняется | Что видит | Граница | Основной риск |
|---|---|---|---|---|---|
| **Tier 0 — Skill Pack** | `SKILL.md`, prompts, схемы и ресурсы; кода и прав нет | Валидируется как данные и передаётся в контекст как недоверенный контент; process и isolate не создаются | Только явно переданные данные контекста; не получает env, secrets, filesystem или network capability | Контентная граница и provenance, не sandbox | Prompt injection или tool poisoning при просмотре человеком/моделью; исполняемый код отсутствует |
| **Tier 1 — Trusted Module** | Первопартийный или ревьюнутый Dart-код | Линкуется в AOT-бинарь при сборке и регистрируется codegen-регистром; изолят используется только для локализации ошибок и разделения CPU | Всё, что доступно доверенному коду в процессе и VM, включая process-level authority | Доверие на этапе сборки; изолят не является security boundary | Ошибка, `exit()`, FFI или неисправность могут повлиять на process |
| **Tier 2 — Untrusted Module** | Произвольный код marketplace, поставляемый как precompiled AOT executable | Проверка подписи и digest → отдельный process → Linux `bwrap`/`nsjail`, cgroup v2 и seccomp → `core.initialize`; сеть выключена | Только отдельный workspace, минимальное окружение и opaque capability IDs; core secrets и raw credentials недоступны | Process + OS sandbox + capability broker; при невозможности — fail-closed отказ | Sandbox escape, resource abuse, ошибки broker и попытка egress; отказ безопаснее деградации |

Контент Tier 0 и результаты внешних инструментов получают provenance-метки (`trusted_user`, `untrusted_web`, `untrusted_tool_output`, `private_data`, `secret`) на границе типов. Такой контент информирует модель, но не выдаёт capability и не разрешает egress; lethal trifecta разрывается отсутствием у недоверенного контекста прямой эмиссии и полномочий. Все сетевые операции Tier 2 проходят через broker, который проверяет destination, method, redirect, размер, credential scope и rate limit.

Изолят не является границей безопасности. В изоляте доступны `Platform.environment`, `dart:io exit()`, FFI и `DynamicLibrary.open()`, а VM Service может расширить полномочия наблюдаемого процесса; per-isolate лимитов CPU и памяти в API Dart нет. Tier 2 никогда не линкуется в ядро и не исполняется в изоляте ядра. Ограничения и следствия этой модели разобраны в §19.

Платформенная политика:

- **Linux.** Tier 2 поддерживается первым: `bwrap` или `nsjail`, cgroup v2 (`memory.max`, `cpu.max`, `pids.max`), seccomp, network namespace без egress и kill всей process group по таймауту. Наружу остаётся только Unix-socket capability broker.
- **macOS и Windows.** До появления платформенного supervisor'а Tier 2 не поддерживается. Результат — явный видимый отказ; откат на `dart:isolate` запрещён.
- **Web.** Поддерживается только Tier 0. Tier 1 и Tier 2 не запускаются: в web нет `dart:io`, OS process и изолятов. Web-реализация `alteri_one_platform` является будущим transport/storage вариантом, не v1 CLI.

Правило fail-closed едино для всех платформ: недоступный sandbox, недоступный broker, некорректный манифест, несовместимая версия или нарушение policy приводят к отказу. Более слабый режим не выбирается автоматически. Манифест декларирует capability; фактический набор равен пересечению manifest, profile, user policy, admin policy и deployment policy. `deny` всегда побеждает `confirm`, а `confirm` — `allow`.

**Tier 0 — это то, с чего начинается marketplace; декларативные Skill Pack не требуют OS-песочницы, поэтому её отсутствие не блокирует Фазу 0.**

## 4. Протокол JSON-RPC 2.0

### 4.1. Конверт

`jsonrpc` всегда равен `"2.0"`. Поле `type` — дискриминант AlteriOne envelope: `request`, `response`, `notification` или `event`. Поля `id`, `method`, `params`, `result` и `error` имеют JSON-RPC-совместимые правила; `type` и `module` — расширения AlteriOne, а namespace задаётся полем `module` и namespaced-методом.

Request:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "request",
  "id": "req_01",
  "module": "core",
  "method": "core/run",
  "params": {
    "goal": "Подготовить краткий отчёт",
    "profile": "companion",
    "context": {}
  },
  "meta": {
    "proto": 1,
    "moduleVersion": "1.0.0",
    "deadlineMs": 300000,
    "idempotencyKey": "run_01"
  }
}
```

Response; `body` содержит либо `result`, либо `error`:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "response",
  "id": "req_01",
  "module": "core",
  "result": {
    "status": "completed",
    "answer": "Отчёт подготовлен"
  },
  "meta": {
    "proto": 1,
    "moduleVersion": "1.0.0",
    "latencyMs": 120
  }
}
```

Notification; `id` отсутствует:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "notification",
  "module": "core",
  "method": "$/progress",
  "params": {
    "requestId": "req_01",
    "progress": 0.5,
    "message": "Обработана половина шагов"
  },
  "meta": {
    "proto": 1,
    "moduleVersion": "1.0.0"
  }
}
```

Event; одностороннее событие модуля, `id` отсутствует:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "event",
  "module": "core",
  "topic": "core/step_completed",
  "data": {
    "step": 2,
    "status": "ok"
  },
  "traceId": "trace_01",
  "meta": {
    "proto": 1,
    "moduleVersion": "1.0.0"
  }
}
```

`Request` и `Response` требуют строковый `id`; `Notification` и `Event` не имеют `id`. Отсутствие ответа на notification/event не является ошибкой. Поля `meta.proto` и `meta.moduleVersion` не взаимозаменяемы.

### 4.2. Sealed union в Dart

Typed union генерируется `freezed`; `params`, `result` и `error` декодируются generated codec-ами, а не приводятся к `dynamic`.

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'envelope.freezed.dart';

@freezed
sealed class AlteriOneEnvelope with _$AlteriOneEnvelope {
  const factory AlteriOneEnvelope.request({
    required String id,
    required String module,
    required String method,
    required AlteriOneParams params,
    required AlteriOneMeta meta,
  }) = Request;

  const factory AlteriOneEnvelope.response({
    required String id,
    required String module,
    required AlteriOneResponseBody body,
    required AlteriOneMeta meta,
  }) = Response;

  const factory AlteriOneEnvelope.notification({
    required String module,
    required String method,
    required AlteriOneParams params,
    required AlteriOneMeta meta,
  }) = Notification;

  const factory AlteriOneEnvelope.event({
    required String module,
    required String topic,
    required AlteriOneParams data,
    required String traceId,
    required AlteriOneMeta meta,
  }) = Event;
}

@freezed
class AlteriOneMeta with _$AlteriOneMeta {
  const factory AlteriOneMeta({
    required int proto,
    required String moduleVersion,
  }) = _AlteriOneMeta;
  const AlteriOneMeta._();
}

@freezed
sealed class AlteriOneResponseBody with _$AlteriOneResponseBody {
  const factory AlteriOneResponseBody.result(AlteriOneResult result) = ResultBody;
  const factory AlteriOneResponseBody.error(AlteriOneError error) = ErrorBody;
}
```

`AlteriOneResponseBody` делает mutually exclusive наличие `result` и `error` частью типа. Исчерпывающий `switch` по `Request`, `Response`, `Notification` и `Event` отклоняет неизвестный discriminant на этапе generated validation.

### 4.3. Фрейминг и лимиты

Для потоковых транспортов используется LSP-style framing:

```text
Content-Length: <N>\r\n
Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n
\r\n
<payload ровно N байт UTF-8>
```

`N` — количество байт payload, не количество символов. Receiver буферизует частичные чтения, принимает только полный header block и затем ровно один JSON payload. NDJSON и необрамлённый JSON по stdio не допускаются. Диагностический вывод пишется в отдельный поток stderr, чтобы не смешиваться с protocol stream.

| Лимит | Значение | Поведение при превышении |
|---|---:|---|
| Максимальный frame | 8 MiB (8 388 608 байт) | Закрыть или отклонить соединение до полного frame |
| Максимальный header block | 8 KiB | Ошибка framing |
| Максимальная глубина JSON | 64 уровня | Ошибка валидации params/result |
| Одновременные in-flight requests | 32 на peer | Ограничить очередь и применить backpressure |
| Ожидающие responses в очереди | 256 на peer | Отклонить новое превышение либо применить backpressure |

Значения выше являются hard defaults; `core.initialize` может согласовать меньшие значения, но не больше hard cap. Sender ограничивает скорость чтения и запись при заполнении bounded queue. Ограничение frame не заменяет лимиты памяти процесса Tier 2.

### 4.4. Отмена и прогресс

Отмена — notification `$/cancelRequest` с идентификатором исходного request и причиной:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "notification",
  "module": "core",
  "method": "$/cancelRequest",
  "params": {
    "id": "req_01",
    "reason": "user_interrupt"
  },
  "meta": {
    "proto": 1,
    "moduleVersion": "1.0.0"
  }
}
```

Cancellation идемпотентна, не требует отдельного response и каскадирует через `CancelToken` в subagent, tool call и process group Tier 2. Гонка между завершением и отменой разрешается в пользу уже завершённого результата; незавершённый запрос получает `-32031`. `$/progress` — notification с `requestId`, монотонным `progress` в диапазоне `0.0..1.0`, необязательными `total` и `message`; прогресс не содержит secrets и не меняет policy.

### 4.5. Handshake `core.initialize`

Первым запросом сессии является `core.initialize`: модуль отправляет его ядру через выбранный transport, а ядро отвечает результатом negotiation. До `accepted: true` capability не публикуются и обычные методы не принимаются.

```jsonc
{
  "jsonrpc": "2.0",
  "type": "request",
  "id": "init_01",
  "module": "core",
  "method": "core.initialize",
  "params": {
    "protoVersionRange": ">=1.0.0 <2.0.0",
    "moduleVersion": "1.2.0",
    "capabilities": [
      "skill:web_search"
    ],
    "limits": {
      "maxFrameBytes": 8388608,
      "maxJsonDepth": 64,
      "maxConcurrentRequests": 32
    }
  },
  "meta": {
    "proto": 1,
    "moduleVersion": "1.2.0"
  }
}
```

```jsonc
{
  "jsonrpc": "2.0",
  "type": "response",
  "id": "init_01",
  "module": "core",
  "result": {
    "accepted": true,
    "negotiatedProto": "1.0",
    "degradePolicy": "refuse",
    "limits": {
      "maxFrameBytes": 8388608,
      "maxJsonDepth": 64,
      "maxConcurrentRequests": 32
    }
  },
  "meta": {
    "proto": 1,
    "moduleVersion": "1.2.0"
  }
}
```

`degradePolicy` допускает только явно выбранные `refuse` или `warn+degrade`; значение не выбирается по догадке. Capability mismatch, несовместимый protocol или нарушение security policy завершают handshake с `accepted: false` и `-32050`.

### 4.6. Версионирование

- `proto` — версия envelope/protocol, передаваемая в `meta` и участвующая в `protoVersionRange`; это версия wire-контракта. В примерах `proto: 1` обозначает major, а `protoVersionRange` задаётся semver-строкой.
- `moduleVersion` — semver манифеста конкретного модуля; он описывает реализацию и capability contract, но не заменяет `proto`.
- В пределах одного major `proto` меньшие изменения обратно совместимы; неоднозначное или major-изменение требует нового negotiation.
- Ограничения semver манифеста разрешаются до запуска. При отсутствии совместимой версии действует `-32050`; автоматический downgrade, смена trust tier и пропуск обязательной capability запрещены.
- `warn+degrade` допускается лишь для явно необязательной capability и только при заранее определённой policy. Для sandbox, secrets, egress и Tier 2 несовместимость всегда означает fail-closed.

### 4.7. Коды ошибок

Retry определяется видом операции; side-effecting tool повторяется только с `idempotencyKey`. «Скормить модели» означает, что в model-visible error data можно включить очищенные параметры или причину, но не credentials и не private data.

| Code | Смысл | Retry | Скормить модели |
|---:|---|---|---|
| `−32700` | Parse error: невалидный JSON или payload | нет | нет |
| `−32600` | Invalid request: нарушен envelope JSON-RPC | нет | нет |
| `−32601` | Method not found | нет | нет |
| `−32602` | Invalid params | нет | да, очищенные params |
| `−32603` | Internal error | возможен для transient-причины | да |
| `−32001` | Provider unavailable | с backoff | да |
| `−32002` | Rate limited, с `Retry-After` | после `Retry-After` | нет |
| `−32003` | Model refusal или content filter | нет | да |
| `−32010` | Tool завершился ошибкой | по capability | да |
| `−32011` | Tool timeout | один retry | да |
| `−32020` | Policy denied | нет | да |
| `−32021` | Approval declined | нет | да |
| `−32030` | Deadline exceeded | нет | нет |
| `−32031` | Cancelled | нет | нет |
| `−32032` | Budget exhausted | нет | нет |
| `−32040` | Sandbox violation или module killed | нет | нет |
| `−32050` | Несовместимость версий | нет | нет |

Диапазон `−32768…−32000` зарезервирован JSON-RPC для implementation-defined ошибок. Доменные коды AlteriOne размещаются именно в нём; стандартные коды `−32700…−32603` сохраняют стандартный смысл.

### 4.8. Транспорты

Один envelope работает поверх трёх transports; transport не меняет policy и trust tier.

| Transport | Назначение | Framing и ограничения |
|---|---|---|
| `stdio` | CLI ↔ core и Tier 2 process boundary | **Требует явный `Content-Length` framing**; stdout содержит только protocol frames, logs идут в stderr |
| `ipc` | In-process exchange, isolate-to-isolate и parent/child channel | Передаёт тот же envelope через `Concurrency`/platform port; не является security boundary и не применяется к Tier 2 |
| `http` | Удалённые core/embedders и внешние host adapters | HTTP body или stream сохраняет framing и negotiated limits; TLS, authentication и egress authorization остаются обязанностью host/transport |

Отсутствие явного framing в stdio является ошибкой протокола, а не допустимым режимом совместимости. HTTP transport сам по себе не превращает core в MCP server или MCP client; соответствующий dialect adapter остаётся отдельным компонентом.

## 5. YAML-конфигурация

### 5.1. Интерполяция `${ENV_VAR}` и секреты

Строка `${ENV_VAR}` подставляет значение переменной окружения только в строковом YAML-scalar после синтаксического разбора и до schema validation. Значение не исполняется как shell-код; command substitution, произвольные выражения и отсутствующая переменная приводят к ошибке валидации. Секретное значение не записывается обратно в YAML, argv, manifest или лог.

Секреты поступают только из environment. В конфигурации используется имя переменной, например `apiKeyEnv: OPENAI_API_KEY`; значения `${OPENAI_API_KEY}` допускаются только в секретном поле, живут в памяти во время выполнения и редактируются в diagnostics. Tier 2 не получает raw environment и не наследует parent environment: capability broker передаёт только opaque capability id и авторизованный результат.

Отсутствующая переменная, неверное имя или попытка прочитать секрет из repository fixture — диагностируемая ошибка. `alteri_one doctor --validate-config` проверяет наличие переменной, не печатая её значение.

### 5.2. Манифест модуля

Каждый YAML-конфиг имеет `apiVersion` и `kind`. Для модуля v1 используется следующая валидная схема:

```yaml
apiVersion: alteri.one/v1
kind: ModuleManifest
name: example.web_search
moduleVersion: 1.0.0
tier: trusted
entrypoint: WebSearchModule
protocol: ">=1.0.0 <2.0.0"
capabilities:
  - id: skill:web_search
    type: skill
    description: "Поиск публичных страниц по заданному запросу"
    operations:
      - search
    requires:
      - network.egress
dependencies: []
```

`entrypoint` — имя символа, зарегистрированного codegen-регистром для Tier 1, а не путь к файлу и не команда загрузки. Для Tier 2 executable и его digest берутся из подписанного registry; путь процесса в manifest не принимается. `capabilities` описывает требуемые классы capability, но не выдаёт права: enforcement выполняется пересечением manifest с profile, user, admin и deployment policy. Для Tier 0 используется `kind: SkillPack`, поля executable и code отсутствуют. Поля, не соответствующие `apiVersion`/`kind`, отклоняются валидатором.

### 5.3. Профиль

Профиль — версионированные данные persona, model, memory, policy и limits. `model.providers` — упорядоченная цепочка, а не один скрытый provider.

```yaml
apiVersion: alteri.one/v1
kind: Profile
name: companion

persona:
  name: Alteri
  bio: |
    Компаньон помогает в повседневных, личных и деловых задачах,
    сохраняет важные факты и предлагает следующий практический шаг.
  tone: "тёплый, дружелюбный, без жаргона"
  language: ru

capabilities:
  - skill:web_search
  - skill:calendar
  - skill:file_read

model:
  providers:
    - id: openai
      baseURL: "https://api.openai.com/v1"
      apiKeyEnv: OPENAI_API_KEY
      modelId: gpt-4o
      requires:
        - tools
        - streaming
      temperature: 0.7
      maxOutputTokens: 4096
    - id: local
      baseURL: "http://localhost:11434/v1"
      modelId: qwen2.5
      requires:
        - streaming

memory:
  enabled: true
  historyTurns: 60
  compaction:
    triggerTokens: 12000
    keepLastTurns: 12
    maxSummaryTokens: 2000

policy:
  default: allow
  rules:
    - match:
        tool: shell_run
      effect: confirm
    - match:
        tool: file_delete
      effect: confirm
    - match:
        tool: file_delete
        pathGlob: "~/.ssh/**"
      effect: deny
    - match:
        tool: file_read
        pathGlob: "~/.env"
      effect: deny
  egress:
    - host: "api.github.com"
      methods:
        - GET

budgets:
  maxSteps: 40
  deadline: 300s
  toolTimeout: 60s
  modelTimeout: 90s
  maxCostUsdPerRun: 0.50
  maxTokensPerRun: 500000
  stagnationWindow: 3

logging:
  format: jsonl
  redaction:
    - secret
    - private_data
```

`historyTurns` измеряется в turns, а `triggerTokens`, `maxSummaryTokens` и `maxTokensPerRun` — в токенах; смешивать эти единицы нельзя. `requires` проверяется capability-пробой provider и не означает, что любой OpenAI-compatible endpoint поддерживает одинаковые tools или streaming. `policy.default` действует только внутри уже выданной capability; `policy.default` и `policy.rules` вычисляются с фиксированным приоритетом `deny > confirm > allow`. Сначала выбирается наиболее строгий effect; specificity используется только для tie-break внутри одного effect, поэтому конфликт `allow` разрешается в `deny`. `egress` ограничивает допустимые host и methods для capability broker. Все secrets представлены именами environment-переменных, а не значениями.

### 5.4. Четыре уровня конфигурации и прецедент

| Приоритет | Уровень | Источник | Правило конфликта |
|---:|---|---|---|
| 0 | Встроенный | Dart-объекты в бинаре | Заменяется любым следующим уровнем |
| 1 | Пользовательский | `~/.alteri_one/` | Заменяет встроенное значение |
| 2 | Проектный | `./.alteri_one/project.yaml` | Заменяет пользовательское значение |
| 3 | CLI | Флаги запуска | Заменяет значение из YAML для текущего запуска |

Слияние выполняется после валидации `apiVersion` и `kind`. Для scalar-полей действует правило «больший приоритет побеждает». Mapping-поля сливаются по ключу; списки provider/capability заменяются целиком, если не задана отдельная нормативная семантика. `policy.rules` и `policy.egress` объединяются, после чего вычисляется наиболее строгий effect. `deny` не может быть переопределён `allow`; отсутствие правила не означает разрешение, если capability не выдана.

Порядок policy-источников: profile → пользовательские `~/.alteri_one/policies.d/` → admin (`/etc` или deployment path) → deployment policy. Это отдельные policy inputs, а не пятый уровень обычной конфигурации. Каждый источник добавляет ограничения; итоговое решение — пересечение политик, а не выбор одного «безопасного» файла. Деструктивные операции, чтение secrets, egress и Tier 2 дополнительно требуют подтверждения или запрета согласно policy.

`alteri_one doctor --validate-config` запускает schema validation после слияния и для каждой ошибки печатает файл, строку и JSON/YAML-путь до поля. Несовместимый `apiVersion` не мигрируется молча: требуется явная migration. Каталог `config/` репозитория не входит в этот поиск и используется только как fixture.

### 5.5. Персоны

- **companion** — личная и бизнес-помощь, тёплый дружелюбный тон, рабочая и личная память; подходит для повседневного диалога и планирования.
- **business** — task-oriented профиль с большим набором инструментов для email, CRM и analytics, рабочей памятью, деловым тоном и минимальным личным контекстом.
- **developer** — профиль автономной разработки с доступом к репозиторию, dev-tools как skills, проектной памятью и системным промптом автономного разработчика; опасные git/shell operations требуют подтверждения.

Переключение профиля меняет только загруженные данные: persona, prompts, provider settings, memory namespace, policy и локализованные строки. Код ядра, AOT-бинарь, протокол, registry и реализации модулей не переключаются; «три личности» остаются тремя конфигурациями одного core.

### 5.6. Интернационализация

`intl` подключается с Фазы 0. Поле `language: ru` в профиле задаёт locale persona и проверяется по реестру поддерживаемых локалей. Пользовательские строки CLI, ошибки, подтверждения и тексты интерфейса проходят через l10n-каталоги и generated accessors; в коде не остаётся захардкоженных русских или английских фраз. Переключение языка также не меняет исполняемый код ядра.

## 6. Провайдеры

Единый wire v1 — OpenAI-compatible Chat Completions. Локальный OpenAI-совместимый сервер подключается как обычный provider; отдельная загрузка локальной модели через FFI в v1 не требуется. Совместимость wire не означает тождество API конкретной модели: каждая пара `endpoint + model` имеет собственную матрицу возможностей.

```dart
abstract interface class AlteriOneProvider {
  String get id;

  /// Возможности именно связанной пары endpoint + model.
  Future<AlteriOneModelCapabilities> probe();

  Stream<AlteriOneChatChunk> chat(
    AlteriOneRequest request, {
    required String model,
    required Deadline deadline,
    required CancelToken cancel,
  });
}
```

`AlteriOneProvider` не инкапсулирует конкретный SDK провайдера. Реализация OpenAI-compatible строится на `package:http` и собственных типизированных DTO: это сохраняет единый wire, но не наследует opinionated типы и невалидные допущения стороннего SDK. Ошибки HTTP/transport преобразуются в таксономию JSON-RPC из §4.7; исходный код и тело ответа сохраняются только в redacted-диагностике.

### 6.1 Capabilities и обязательные `requires`

```dart
final class AlteriOneModelCapabilities {
  const AlteriOneModelCapabilities({
    required this.tools,
    required this.parallelTools,
    required this.streaming,
    required this.jsonMode,
    required this.promptCaching,
    required this.seed,
    required this.contextWindow,
  });

  final bool tools;
  final bool parallelTools;
  final bool streaming;
  final bool jsonMode;
  final bool promptCaching;
  final bool seed;
  final int contextWindow;
}
```

`probe()` не доверяет самодекларации OpenAI-compatible endpoint: она проверяет минимальный capability handshake и сохраняет результат вместе с `providerId`, `modelId`, `baseURL` и временем пробы. Значение `contextWindow` валидируется как положительное число; неизвестная возможность представляется отсутствующим флагом, а не безусловным `true`.

Профиль объявляет несовместимость заранее:

```yaml
model:
  providers:
    - id: openai
      baseURL: https://api.openai.com/v1
      apiKeyEnv: OPENAI_API_KEY
      modelId: gpt-4o
      requires: [tools, streaming]
      temperature: 0.7
      maxOutputTokens: 4096
    - id: local
      baseURL: http://localhost:11434/v1
      modelId: qwen2.5
      requires: [streaming]
```

После `probe()` ядро валидирует `requires` до первого model turn. Если локальный сервер не поддерживает tools, JSON mode или seed, это отказ конкретной пары `provider + model`, а не загадочный HTTP 400 в середине прогона. Model-agnostic означает переносимость через общий wire, но не ложное обещание, что облако и локальный сервер поддерживают одинаковые tools, JSON mode, parallel calls, prompt caching, seed и context window.

### 6.2 Streaming с первого дня

Единственный `chat()` возвращает `Stream<AlteriOneChatChunk>`. Стриминг входит в контракт с первой версии, потому что CLI должен показывать первые токены, `deadline` и `CancelToken` должны прерывать ожидание, а UI должен видеть backpressure. Retrofit интерфейса после появления первого клиента меняет все реализации, command-фабрики и тестовые doubles; streaming в базовом контракте почти не стоит дороже его отсутствия.

Поток содержит текстовые/tool chunks, финальный результат и нормализованный `usage`. Non-streaming endpoint может реализовать интерфейс адаптером, который выдаёт один итоговый chunk, но обратная трансформация streaming API в batch-only интерфейс запрещена.

### 6.3 Usage и стоимость

`usage` обязателен в каждом успешно завершённом model turn и агрегируется `CostBudget` до следующего шага. Нормализованная запись содержит input, output, cached-input и total tokens; USD-стоимость вычисляется по версионированному price table из конфигурации. Если ценовая таблица отсутствует, provider с `maxCostUsdPerRun` не допускается к запуску — нельзя объявить денежный бюджет и затем не учитывать расход.

При stream error, если провайдер сообщил уже понесённый `usage`, он также учитывается. Повторный запрос не создаёт второй бюджет: retries принадлежат исходной операции, и их usage суммируется.

### 6.4 Цепочка провайдеров и circuit breaker

`providers: [...]` — упорядоченная цепочка failover, а не список равноправных имён. Первый совместимый provider обслуживает запрос; следующий выбирается только при явно разрешённой деградации, например для ошибки `-32001`, недоступного endpoint или transport timeout. Ошибки policy, отклонённое подтверждение, несовместимость capabilities и exhausted budget не являются поводом обойти отказ через другой provider.

Для каждого provider ведётся circuit breaker `closed → open → half_open`: подтверждённая серия retryable отказов открывает circuit, cooldown запрещает холодные пробы, успешный half-open probe закрывает circuit. Failure и cooldown задаются политикой провайдера; jitter использует инъецируемый источник случайности. Failover не должен незаметно менять billing class: переход между платным и локальным provider фиксируется в trace и transcript.

### 6.5 Повторы и идемпотентность

Provider retry допустим только для ошибок, помеченных retryable в таксономии §4.7, с backoff и `Retry-After` для rate limit. Повтор одного вызова использует один `idempotencyKey`; новый ключ означает новую операцию. Model turn сам по себе read-only, но provider-generated tool call не считается разрешением повторить выбранный инструмент.

Автоматический retry side-effecting-инструмента без `idempotencyKey` запрещён. Наличие ключа не отменяет policy и не превращает confirmation в бессрочное разрешение: approval и ключ привязаны к точным аргументам.

## 7. Память

### 7.1 Типизированные записи

Long-term память хранит закрытое множество записей, а не произвольный `Map<String, dynamic>`:

```dart
enum Provenance { userStated, modelInferred, toolObserved }
enum MemoryTrust { trusted, untrusted }

sealed class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.createdAt,
    required this.lastSeenAt,
    required this.provenance,
    required this.trust,
    required this.confidence,
    required this.ttl,
    required this.supersededBy,
  }) : assert(confidence >= 0 && confidence <= 1);

  final String id;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final Provenance provenance;
  final MemoryTrust trust;
  final double confidence;
  final DateTime? ttl;
  final String? supersededBy;
}

final class FactRecord extends MemoryRecord {
  const FactRecord({
    required super.id,
    required super.createdAt,
    required super.lastSeenAt,
    required super.provenance,
    required super.trust,
    required super.confidence,
    required super.ttl,
    required super.supersededBy,
    required this.key,
    required this.value,
  });

  final String key;
  final String value;
}

final class EpisodeRecord extends MemoryRecord {
  const EpisodeRecord({
    required super.id,
    required super.createdAt,
    required super.lastSeenAt,
    required super.provenance,
    required super.trust,
    required super.confidence,
    required super.ttl,
    required super.supersededBy,
    required this.summary,
    required this.artifactIds,
  });

  final String summary;
  final List<String> artifactIds;
}

final class PreferenceRecord extends MemoryRecord {
  const PreferenceRecord({
    required super.id,
    required super.createdAt,
    required super.lastSeenAt,
    required super.provenance,
    required super.trust,
    required super.confidence,
    required super.ttl,
    required super.supersededBy,
    required this.topic,
    required this.pref,
  });

  final String topic;
  final String pref;
}

final class ArtifactRecord extends MemoryRecord {
  const ArtifactRecord({
    required super.id,
    required super.createdAt,
    required super.lastSeenAt,
    required super.provenance,
    required super.trust,
    required super.confidence,
    required super.ttl,
    required super.supersededBy,
    required this.path,
    required this.mime,
    required this.bytes,
  });

  final String path;
  final String mime;
  final List<int> bytes;
}
```

JSON-представление сохраняет wire-имена provenance `user_stated | model_inferred | tool_observed`. `ttl` — абсолютный момент истечения, а не бессрочное значение; `lastSeenAt` обновляется только при подтверждённом повторном наблюдении. `confidence` не является политикой доступа: доверенность задаёт host-код.

Инварианты записи:

- Модель не может выбрать provenance и не может записать `trusted` record. Модельный вывод всегда `modelInferred/untrusted`, даже если формулировка выглядит как факт.
- `userStated` назначает только доверенный пользовательский канал. `toolObserved` становится trusted лишь после детерминированной проверки источника host-кодом; результат неизвестного внешнего инструмента остаётся untrusted.
- `modelInferred/trusted` и `toolObserved/trusted` без подтверждённого host-источника отклоняются storage adapter до записи.
- Секреты не записываются в память. Приватные данные требуют явной retention policy и отдельной sensitivity label `private_data`; memory provenance при этом остаётся одним из `user_stated | model_inferred | tool_observed`.
- Конфликт одинакового логического ключа разрешается по времени: новое подтверждённое `user_stated` или host-verified `tool_observed` assertion становится текущим, предыдущая версия сохраняется и получает `supersededBy`. Untrusted record не вытесняет trusted и остаётся кандидатом. Молчаливая перезапись запрещена; молчаливый выбор старой версии при равном времени также запрещён.
- Чтение по умолчанию возвращает актуальные записи; superseded-записи доступны для provenance, export и аудита, но не подмешиваются в prompt без явного запроса.

### 7.2 Short-term и long-term

Short-term memory — активный контекст текущей сессии: system/profile instructions, goal, plan, последние turns и незавершённые tool outcomes. Она не переживает завершение run и не становится долговременной только из-за числа сообщений.

Long-term memory реализуется на `hive_ce` с `hive_ce_generator`; коллекции: `sessions`, `messages`, `facts`, `episodes`, `preferences`, `artifacts`. Native storage вызывается только через `AlteriOneStorage`/`AlteriOnePaths` из `alteri_one_platform`; ядро не импортирует `dart:io` и не открывает Hive напрямую.

Runtime state размещается под корнем профиля:

```text
~/.alteri_one/state/<profile>/
├── global/
└── projects/<project-key>/
```

`<profile>` и `<project-key>` нормализуются и не позволяют выйти за корень state. Ключ каждой записи включает profile и project namespace, поэтому поиск без namespace невозможен. Даже одинаковый project root в разных профилях не разделяет факты, эпизоды, предпочтения или транскрипты. Project key вычисляется из канонического project root через `AlteriOnePaths`, а не из произвольного пользовательского пути.

### 7.3 Compaction по токенам

Единица триггера — токены, а не число сообщений. `memory.compaction.triggerTokens` сравнивается с `state.contextTokens`, который обновляется только из проверенного `usage` провайдера. Количество сообщений, символов и приблизительная локальная оценка не могут заменить provider usage. `CostBudget.tokensUsed` остаётся отдельным счётчиком расхода всего run и не подменяет размер текущего контекста.

Алгоритм детерминирован:

1. После model turn нормализованный usage обновляет `state.contextTokens` и общий `CostBudget`.
2. При `contextTokens >= triggerTokens` compaction получает transcript в стабильном порядке, фиксированный template, pinned IDs и заданный `maxSummaryTokens`.
3. Последние `keepLastTurns` сохраняются дословно; более старый контекст заменяется версионированным summary и ссылками на сохраняемые записи/артефакты.
4. Usage compaction-сводки учитывается в том же `CostBudget`; compaction не выполняется после исчерпания deadline, budget или cancellation.
5. Один и тот же transcript, FakeProvider script, fake clock и seed id generation дают один и тот же state transition и snapshot памяти.

Сохраняются: исходная цель, persona/profile instructions, активный plan, pinned facts, явные пользовательские предпочтения, незавершённые tool calls, ссылки на нужные artifacts и последние turns. Не сохраняются в компактном prompt: полные дублированные transcript-фрагменты, истёкшие записи, секреты, несекретные приватные данные без retention policy, недоверенные web/tool-инструкции с правами инструкций.

Компакция не повышает trust и не меняет provenance. Извлечённые моделью утверждения сохраняются как `modelInferred/untrusted`; в trusted memory попадает только отдельный ранее подтверждённый record. Сводка не может исполнить tool, получить capability или объявить содержимое untrusted tool результата системной инструкцией.

### 7.4 `VectorIndex`

Recall по embeddings скрыт за отдельным контрактом:

```dart
abstract interface class VectorIndex {
  Future<void> upsert(
    String id,
    List<double> embedding, {
    required Map<String, Object?> meta,
  });

  Future<List<ScoredId>> query(
    List<double> query, {
    int k = 10,
    Map<String, Object?> filter = const <String, Object?>{},
  });

  Future<void> remove(String id);
}
```

В v1 есть интерфейс и exact/lexical retrieval, но нет ANN-реализации. Hive — KV-хранилище без approximate nearest-neighbor индекса; его brute-force scan не выдаётся за vector search. Реализация выбирается позднее по измерению recall, latency, web/native compatibility и эксплуатационной сложности. FFI и локальные модели для recall также вне v1.

### 7.5 Приватность и retention

Export, forget и retention являются продукт-требованиями, а не внутренними convenience-командами:

```bash
alteri_one memory list --profile companion
alteri_one memory export --profile companion --output memory.json
alteri_one memory forget --profile companion --id mem_01
```

- `list` показывает id, kind, provenance, trust, confidence, TTL и namespace без полного приватного payload по умолчанию.
- `export` имеет явный selector scope, версионированный JSON-формат и manifest с checksum. Секреты всегда исключаются; приватные данные требуют явного opt-in и redaction preview.
- `forget` принимает record id либо ограниченный selector, показывает объём удаления и требует подтверждения для bulk scope. Удаление создаёт tombstone от восстановления из compaction/cache и не оставляет backup-копию в profile state.
- Retention применяется к sessions, transient tool content, superseded records и artifacts. TTL проверяется при запуске и перед выдачей в prompt; resurfacing просроченной записи не обходит проверку.
- Telemetry не содержит memory payload. Diagnostics и transcript используют те же redaction policies, что и provider/tool boundaries.

## 8. Reasoning loop

### 8.1 Стратегии

Движок детерминирован и не знает конкретных skills, MCP tools, модулей или бизнес-доменов. Он работает только с типизированными состоянием, tool-call и capability registry.

```dart
abstract interface class ReasoningStrategy {
  Future<ReasoningTurn> next(
    ReasoningState state, {
    required CancelToken cancel,
  });
}
```

`ReasoningStrategy` преобразует состояние в следующий turn, но не исполняет произвольный код и не обходит engine controls: deadline, budget, policy, capability lookup, tool validation и cancellation остаются host-контролем.

В v1 существует одна реализация — ReAct:

1. Engine передаёт модели цель, разрешённые capability schemas и текущий контекст.
2. Streaming model turn возвращает либо финальный ответ, либо один или несколько `tool_call`.
3. Engine валидирует tool id, JSON arguments и declared capabilities без знания о семантике инструмента.
4. После `Allowed` или подтверждения tool вызывается, а его `ToolOutcome` добавляется в контекст следующего turn.
5. После denied, declined, failure или retry model получает результат операции и выбирает следующий turn.
6. Финальный ответ завершает run; `maxSteps`, застой и внешние лимиты также могут завершить его.

`plan-execute` и recursive multi-agent strategy не входят в v1. Добавление новой стратегии не должно менять policy, budget, protocol или persistence contracts.

### 8.2 Цикл

Псевдокод использует typed error outcomes, а не исключения для обычных отказов. Коды и retryability берутся из §4.7.

```dart
Future<AlteriOneRunResult> run(
  AlteriOneRunRequest request, {
  required CancelToken cancel,
}) async {
  final profile = request.profile;
  final clock = request.clock;
  final state = request.initialState;
  final policy = request.policy;
  final deadline = Deadline(
    startedAt: clock.now(),
    limit: profile.budgets.deadline,
  );
  final budget = CostBudget(
    maxUsd: profile.budgets.maxCostUsdPerRun,
    maxTokens: profile.budgets.maxTokensPerRun,
  );

  while (true) {
    if (cancel.isCancelled) {
      return state.finish(Failed(Cancelled()));
    }
    if (deadline.isExpired) {
      return state.finish(Failed(Timeout(remaining: Duration.zero)));
    }
    if (budget.isExhausted) {
      return state.finish(Failed(BudgetExceeded(spent: budget.spent)));
    }
    if (state.steps >= profile.budgets.maxSteps) {
      return state.finish(StepLimit(steps: state.steps));
    }
    if (await state.isStagnant(profile.budgets.stagnationWindow)) {
      return state.finish(Stagnant(repeat: state.lastRepeat));
    }

    final turn = await _model(deadline, budget, cancel);
    if (turn.isFinal) {
      return state.finish(turn.finalResult);
    }

    for (final step in turn.steps) {
      if (cancel.isCancelled) {
        return state.finish(Failed(Cancelled()));
      }
      if (deadline.isExpired) {
        return state.finish(Failed(Timeout(remaining: Duration.zero)));
      }
      if (budget.isExhausted) {
        return state.finish(Failed(BudgetExceeded(spent: budget.spent)));
      }
      if (state.steps >= profile.budgets.maxSteps) {
        return state.finish(StepLimit(steps: state.steps));
      }

      final decision = await policy.evaluate(
        step,
        profile,
        deadline: deadline.child(profile.budgets.toolTimeout),
        cancel: cancel,
      );
      switch (decision) {
        case Denied(:final reason):
          state.record(step, ToolOutcome.denied(reason));
        case NeedsApproval(:final prompt):
          if (await ui.confirm(
            prompt.redacted(),
            deadline: deadline.child(profile.budgets.toolTimeout),
            cancel: cancel,
          )) {
            await _invoke(step, deadline, budget, cancel);
          } else {
            state.record(step, ToolOutcome.userDeclined());
          }
        case Allowed():
          await _invoke(step, deadline, budget, cancel);
      }
    }

    if (state.contextTokens >= profile.memory.compaction.triggerTokens) {
      await _compact(state, deadline, budget, cancel);
    }
  }
}
```

`_model` вызывает provider из §6, передаёт `deadline.child(profile.budgets.modelTimeout)`, то есть `min(perCall, remaining)`, потоково принимает chunks, валидирует final `usage` и атомарно зачисляет его в `budget`. `_invoke` аналогично получает `deadline.child(min(toolTimeout, remaining))`, выполняет retry только по retryable classification и записывает `ToolOutcome` в state. Отмена, deadline exceeded, cancelled и budget exhausted являются terminal control outcomes и не подменяются успешным provider response.

### 8.3 Инварианты цикла

- Число model/tool steps не превышает `maxSteps`; модель, tool и subagent не могут увеличить предел.
- Каждый run имеет обязательный finite `Deadline`; `Infinity` и «неограниченный timeout» не принимаются. Per-call timeout всегда не больше оставшегося общего времени.
- Каждый run имеет обязательный `CostBudget` с token и USD ceilings; отсутствующий или невалидный budget — configuration error до model turn.
- `CancelToken` каскадирует в provider stream, tools, subagent tree и будущий Tier 2 process group; pending approval также отменяется.
- Ошибка инструмента — `ToolOutcome`, который видит модель и может исправить. Это неверно для terminal control outcomes `-32030/-32031/-32032`, которые завершают run согласно §4.7.
- Автоматический retry выполняется только для retryable ошибок из §4.7, с backoff, jitter и `Retry-After`; parse, invalid request/params, policy denied и content filter не повторяются.
- Side-effecting tool без `idempotencyKey` не повторяется автоматически. При retry ключ и approval остаются привязанными к неизменённым аргументам.
- Один и тот же tool с канонически одинаковыми аргументами `stagnationWindow` раз подряд — застой; run останавливается, даже если модель меняет текст рассуждения.
- Model, tool и subagent не могут обойти `CostBudget`, deadline, cancellation или policy через внутренний API.
- Compaction запускается по `triggerTokens`, а не по `messages.length`; её собственный provider usage оплачивается тем же budget.

### 8.4 События цикла

Канонический event stream содержит:

- `task_started`;
- `plan_ready`;
- `step_started`;
- `tool_call`;
- `step_completed`;
- `task_done`;
- `subagent_done` — для каждого дочернего run;
- `compacted`.

Каждое событие имеет как минимум `eventId`, `traceId`, `spanId`, `parentSpanId`, `timestamp`, `eventType`, `profile`, `projectId`, `provenance`, `schemaVersion` и redacted payload. `provenance` события указывает источник `host | user | model | tool | module`; он не предоставляет права.

`plan_ready` публикует текущий plan, `tool_call` — точное намерение и policy decision, `step_completed` — терминальный outcome, usage, длительность и error code при наличии. `task_done` всегда завершает root task, включая failure. Событие не эмитится повторно при retry; retries являются полями конкретного `tool_call`.

Event stream — единственный публичный контракт для CLI/UI, notification observers, tracing и tests. UI не читает внутренний state, hooks не подменяют policy, а provider-specific chunks не становятся вторым побочным каналом наблюдаемости.

## 9. Subagents

Subagent — дочерний run с отдельным context window, собственными `Deadline` и `traceId`, результат которого агрегируется в typed `SubagentResult`. Он не наследует скрытые сообщения родителя: получает минимальную задачу, необходимые capabilities и явно redacted inputs. Результат содержит status, answer, evidence/artifact links, usage, cost, duration и error code; raw internal state и credentials наружу не возвращаются.

### 9.1 Инварианты дерева

- Один `CostBudget` принадлежит всему дереву. Родитель резервирует лимит child budget, а provider usage всех потомков settle-ится в общий ledger; создание subagent не создаёт нового бюджета.
- У каждого child deadline, но он не продлевает parent deadline: effective child time равен `min(configured child deadline, parent remaining)`.
- Рекурсия ограничена обязательным `maxDepth`; количество дочерних запусков — `maxSubagentsPerRun`, одновременных — `maxConcurrentSubagents`. Отсутствующий limit считается configuration error, а не бесконечностью.
- Child получает derived `CancelToken`; отмена родителя отменяет весь descendants tree. В будущем Tier 2 завершается process/cgroup tree, а не только корневой PID.
- По умолчанию child использует самую дешёвую модель, способную выполнить контракт задачи. Повышение до более дорогой модели — явное решение стратегии в пределах общего budget, с записью в trace.
- Subagent получает intersection родительских и собственных capabilities. Результат, текст, tool output или proposed tool call не могут расширить scope, выбрать другой provider с новыми секретами или обойти policy.
- Parent проверяет результат и решает, как его использовать; `subagent_done` автоматически не превращает ответ в trusted memory и не исполняет предложенные side effects.

### 9.2 Тир исполнения

В v1 delegation использует Tier 1 Trusted Module: engine-linked AOT code в процессе. Отдельный isolate допустим для локализации ошибок и разделения CPU, но не является security boundary; изоляция контекста также не делает код доверенным.

Tier 2 Untrusted Module для subagent появляется позже: отдельный AOT-executable и OS sandbox, сначала Linux. macOS/Windows до появления supervisor-а fail closed; сеть выключена, секреты доступны только через opaque capability id. Tier 2 никогда не запускается в isolate ядра.

## 10. Политика и хуки

Hooks переименованы в единую подсистему `policy`. Подтверждения, запреты и Observability больше не дублируются в profile и отдельном `config/hooks.yaml`. `policy` принимает решение до любого side effect; отдельный `notifications` только наблюдает.

```dart
sealed class PolicyDecision {
  const PolicyDecision();
}

final class Denied extends PolicyDecision {
  const Denied(this.reason);
  final String reason;
}

final class NeedsApproval extends PolicyDecision {
  const NeedsApproval(this.prompt);
  final ApprovalPrompt prompt;
}

final class Allowed extends PolicyDecision {
  const Allowed();
}
```

`bool` не используется: `Denied` и `NeedsApproval` содержат machine-readable reason и, при необходимости, redaction-aware prompt. Policy evaluate получает resolved tool call, аргументы, origin/provenance, profile, declared capabilities и identity модуля; решение детерминировано до вызова.

### 10.1 Правила и precedence

```yaml
policy:
  default: allow
  rules:
    - match:
        tool: shell_run
      effect: confirm
    - match:
        tool: file_delete
      effect: confirm
    - match:
        tool: file_delete
        pathGlob: "~/.ssh/**"
      effect: deny
    - match:
        tool: file_read
        pathGlob: "~/.env"
      effect: deny
notifications:
  - event: task_done
    channel: log
  - event: subagent_done
    channel: status
```

Profile, user (`~/.alteri_one/policies.d/`), admin и deployment policies объединяются, а не перезаписывают друг друга. Для всех совпавших rules применяется строгий precedence: `deny > confirm > allow`. При одинаковом effect выигрывает наиболее специфичное правило: exact resource/operation выше resource glob, glob с origin выше tool-only, tool-only выше global default. При полном равенстве specificity и effect правило должно быть unique; конфликт — configuration error.

`Allowed` не предоставляет capability сверх манифеста, профиля, OS sandbox и secret broker. Если capability enforcement или sandbox не удались, policy outcome — `Denied`, а не тихий fallback.

### 10.2 Подтверждение

Для `NeedsApproval` UI показывает не только имя инструмента, а sufficient context для решения:

- цель и human-readable результат классификации;
- нормализованные arguments и затрагиваемые resources;
- file diff, preview записи/сообщения или точный command с cwd и network destinations;
- источник данных и их redaction state;
- ожидаемый side effect и irreversibility;
- `idempotencyKey`, retry count и срок действия approval.

Для send/delete/update confirmation связывает утверждение с digest точных аргументов. Изменение args, destination или capability invalidates approval. Пользовательский decline возвращается модели как `ToolOutcome.userDeclined`; root run не аварийно завершается.

### 10.3 Notifications

`notifications` — чисто наблюдательный список. Он может писать redacted status, отправлять локальное уведомление или подписываться на event stream, но не может approve, deny, veto, retry, менять args или блокировать вызов. Ошибка notification observer не меняет outcome tool и записывается отдельным diagnostic event; policy failures всегда loud и имеют ненулевой exit path.

## 11. Трассировка, тесты и evals

### 11.1 Сквозной trace

Root run создаёт `traceId` инъецируемым генератором. Каждый provider turn, JSON-RPC request, tool, memory operation, subagent и platform adapter получает `spanId` и `parentSpanId`; `traceId` проходит через все границы. Cancellation, deadline и error code связаны с тем же span. Это единый внутренний trace contract, не попытка реализовать OTel.

Transports добавляют correlation id в metadata, но provider/MCP adapters не получают права переопределять внутреннюю семантику событий. Внешний request context может сохраняться отдельно для будущего OTel export.

### 11.2 Транскрипт, replay и `why`

Каждый run пишет versioned JSONL transcript:

1. goal, profile, project и capability snapshot;
2. plan до первого tool call и каждый его revision;
3. каждый step с arguments, approval digest, tool call id, retries, result/error и duration;
4. usage, cache tokens и USD cost после каждого model turn;
5. compaction, budget settlements, subagent edges и terminal outcome.

Аргументы и результаты проходят redaction; секреты не записываются даже в debug mode. Transcript content-addressed и связан с `traceId`, config digest и binary version.

```bash
alteri_one why <traceId>
alteri_one replay <traceId>
```

`why` показывает причинную цепочку: какие входы и policy decisions привели к tool call, какие outcomes изменили следующий turn и почему run завершился. `replay` по умолчанию восстанавливает state machine на recorded provider chunks и tool outcomes без сети и side effects; внешний world effect не считается воспроизведённым. Повторное выполнение side-effecting tool требует отдельного явного режима и новой policy/consent проверки.

Транскрипт дешевле OTel и покрывает большую часть задач «почему агент сделал это», которых не объясняют spans отдельных RPC-вызовов. Поэтому OTel и OTLP вне v1; при появлении зрелого пакета exporter будет читать тот же event/transcript contract, а не заменять его.

### 11.3 Детерминизм

```dart
abstract interface class FakeProvider implements AlteriOneProvider {
  void script(Map<Object, AlteriOneChatResponse> responses);
  void recordTranscript();
  List<ChatTurn> transcript();
}
```

`FakeProvider`, `AlteriOneClock` и `IdGenerator` обязательны в Фазе 0. FakeProvider задаёт scripted chunks, tool calls и нормализованный usage по `(step, profile)`, не обращается к сети и выдаёт полный transcript. Clock задаёт время/deadline/retry, ID generator — request, trace, span, memory и idempotency ids.

Production code не вызывает `DateTime.now`, случайность или process-global id напрямую. Без этих doubles нельзя принять ни один acceptance поведения loop, memory, policy, compaction или subagents: реальная модель не является детерминированным oracle.

### 11.4 Два уровня тестирования

Уровни тестирования не совпадают с тирами исполнения модулей.

| Уровень | Что проверяет | Модель/provider | Когда | Бюджет | Роль в CI |
|---|---|---|---|---|---|
| Tier 1: детерминированные unit / contract / integration tests | Протокол, framing, policy, capabilities, budgets, memory, compaction, loop, tools, cancellation; provider contract через scripted FakeProvider и mocked HTTP | Нет реальной модели | Каждый commit | `$0` | gating |
| Tier 2: eval-набор | Качество поведения: память, соблюдение deny, persona, полезность и error recovery | Реальная закреплённая модель | Вручную или по расписанию | Явный лимит USD, дешёвая модель по умолчанию | Сначала non-gating, затем report-only; gating не входит в первый релиз |

Автоматический «тест качества loop на реальной модели в CI» не принимается: он медленный, платный, flaky из-за sampling/provider changes и невоспроизводимый по seed, server state и цене. Такой набор не доказывает детерминированный контракт и не должен блокировать merge. Contract adapter проверяется на scripted wire, а поведенческие свойства модели живут в eval.

Acceptance-команда завершается кодом 0; термины `unit`, `contract`, `integration` и `eval` не заменяются словом «автотест».

### 11.5 Feedback loop

После run CLI предлагает `👍`, `👎` и reason `это было неверно`. Feedback сохраняет consent, trace reference, model/provider version, redacted transcript excerpt и ожидаемый outcome. Curator eval превращает его в versioned case с явными rubrics, а не в автоматически доверенный training signal.

Новый eval-case проходит дедупликацию, privacy review и baseline comparison. Feedback не меняет system prompt, policy или memory автоматически и не считается доказательством без повторного измерения.

### 11.6 `alteri_one doctor`

```bash
alteri_one doctor --profile developer
alteri_one doctor --profile developer --json
```

Doctor по умолчанию read-only и проверяет:

- schema и `apiVersion` всех resolved profile/policy/manifest configs;
- точную ошибку с `file:line:column` и JSON/YAML path до invalid field;
- env interpolation без вывода secret values;
- provider endpoint, auth availability, `probe()` и соответствие `requires` фактическим capabilities;
- доступность state path, project namespace, прав чтения/записи, свободного места и lock compatibility;
- SDK/Dart versions, package resolution, platform capabilities и Tier 2 fail-closed prerequisites;
- module lifecycle `discovered → validated → linked/loaded → registered → started` и точную причину `почему модуль не загрузился`.

Сетевой probe выполняется только для явно настроенного endpoint и может быть отключён режимом проверки без сети. Doctor не исправляет файлы без явного `--fix`; каждое исправление показывается как patch и проходит повторную validation.

## 12. MCP-интероп

### 12.1 Отдельная подсистема

MCP не является «бесплатной интероперабельностью» с внутренним JSON-RPC envelope. Ревизия протокола `2026-07-28` — отдельный диалект, а не vanilla JSON-RPC 2.0:

- нет handshake `initialize` / `notifications/initialized`;
- нет request batching;
- каждый request несёт `_meta`;
- transport session stateless на уровне протокола, хотя server business state может существовать;
- capability discovery выполняется через `server/discover`;
- сервер не инициирует обычные requests к client.

Следовательно, `alteri_one_mcp` — отдельный adapter package с versioning, negotiation, cancellation, limits и contract tests. Внутренний один envelope не означает реализацию MCP вручную.

### 12.2 Реализация

Базовый выбор v1 — community package `mcp_dart` 2.4.2, поскольку он поддерживает ревизию `2026-07-28`. Альтернатива `dart_mcp` 0.5.2 — official, но experimental; она отслеживается и может заменить baseline только после contract matrix и migration decision. Один активный adapter скрыт за `McpTransport`, но MCP framing, discovery и lifecycle не переписываются вручную.

### 12.3 MCP client

Client подключает AlteriOne к внешним MCP servers и предоставляет selectively enabled `tools`, `resources` и `prompts`. Согласие двухуровневое: пользователь один раз явно разрешает server endpoint/identity, затем отдельно разрешает каждый tool с полным описанием и schema аргументов. Capability не считается разрешённой только потому, что server её объявил.

Config сохраняет protocol revision, package/server version, endpoint identity и digest capability descriptions. Изменение server version, endpoint или description digest инвалидирует прежнее tool consent. Пользователь видит полное описание, имя, required/optional fields, enum, defaults, destructive flag и examples как inert data; HTML и ссылки из description не исполняются.

Resources и prompts поступают как недоверенный контент с provenance. Инструкции server не становятся system prompt автоматически. Tool output проходит те же schema, size, deadline, cancellation, provenance и redaction checks, что и Tier 1 tool.

### 12.4 MCP server mode

AlteriOne может выступать MCP server, но это требует отдельного mapping layer. Наружу не выставляются внутренние `core/*` методы, state fields или unrestricted JSON-RPC. Явные MCP tools строятся поверх curated application capabilities и проходят тот же schema, policy, usage и audit path; resources и prompts также формируются из allowlisted представлений.

Server mode не создаёт новый security tier и не обходит consent клиента. Каждый mapping имеет versioned input/output schema, provenance и deterministic error mapping. Неизвестный internal method не становится MCP method автоматически.

### 12.5 Безопасность MCP

- **Tool poisoning:** description, schema и output server считаются untrusted. Пользователь показывает полный text/schema, policy проверяет фактические args, а server не может изменить system instructions или capability declarations.
- **OAuth:** токен хранится на credential platform boundary, имеет минимальные scopes, short lifetime и отдельную audience для server. Глобальный provider token не переиспользуется; отсутствие необходимого scope — deny.
- **SSRF и redirects:** endpoint проходит allowlist/policy до DNS lookup. Blocked loopback/private/link-local/metadata ranges, alternate ports и schemes; redirects проверяются повторно и не расширяют исходный scope.
- **DNS rebinding:** каждое соединение валидирует фактические A/AAAA destinations, а не только hostname из config; broker не допускает подмены адреса между check и connect.
- **Transport:** TLS, frame/size limits, deadline, cancellation, schema validation и redacted errors обязательны. Server output никогда не получает прямой доступ к env, argv, файлам или внутренним методам AlteriOne.

## 13. Сборка, AOT и дистрибуция

### 13.1 Основной путь CLI

Новый CLI распространяется как Dart CLI package с `executables` и stable build hooks:

```bash
dart build cli
dart install alteri_one
alteri_one doctor
```

`dart build cli` — локальная AOT-сборка package entrypoint. `dart install alteri_one` разрешает зависимости, выполняет build hooks, AOT-компилирует и размещает self-contained native executable в install bundle. В release artifact нет JIT/runtime eval path; `dart run` остаётся development-командой. Это основной пользовательский путь; `dart pub global activate` не является рекомендуемым документированным интерфейсом.

`dart compile exe` и `dart compile aot-snapshot` **не запускают build hooks и завершаются ошибкой при их наличии**. Поэтому они не являются совместимым release path для пакета с `sqlite3`, native assets, Code Assets или любым другим hook dependency. Эти команды допускаются только для hook-free package и никогда не подменяют `dart build cli` в release pipeline.

### 13.2 Целевые платформы v1

v1 поставляет только нативный CLI для Linux, macOS и Windows. Flutter app с Flutter AOT и Flutter web входят в Фазу 5, а не в v1.

`alteri_one_core` не импортирует `dart:io` напрямую. Storage, Http, Clock, Paths, Concurrency и ProcessHost доступны через interfaces `alteri_one_platform`; native/web implementations выбираются conditional imports. Это позволяет сохранить одно ядро для будущего web, но не переносит v1 CLI на web автоматически.

На web нет `dart:io` и обычных `dart:isolate`; concurrency заменяется web workers через `package:web` и ограниченными browser APIs, storage — web implementation, HTTP/paths/process — browser- или remote-backend adapters. Tier 1/2 module execution на web не поддерживается в v1. До начала Фазы 5 отдельно фиксируется web storage и модель process/secret boundary; Tier 2 для browser не обещается.

### 13.3 Целостность и подписи

Каждый опубликованный module manifest содержит protocol/module versions, platform, capability declarations, dependency constraints, digest входа и digest полного AOT artifact. Tier 0 Skill Pack публикуется как подписанные данные и ресурсы без executable; marketplace начинается с этого tier. Tier 1 линкуется в AOT build как trusted code, Tier 2 распространяется как отдельный подписанный AOT executable. Реестр хранит подпись manifest и SHA-256 checksum executable. Перед запуском Tier 1/Tier 2 проверяются checksum, identity и policy compatibility; несовпадение — fail closed.

Подпись доказывает происхождение, не безопасность. Она не доказывает отсутствие вредоносного кода, корректность capability enforcement или безопасность OS sandbox. Tier 2 дополнительно требует работающей OS-изоляции, scrubbed environment и network denial; подпись не заменяет эти требования.

### 13.4 Релиз

Релиз выполняется `melos version` 8.9.0 с coordinated versioning по DAG зависимостей. Перед bump выполняются resolve, codegen, `dart analyze --fatal-infos`, deterministic test matrix, integration tests и migration checks. Версия, changelog и release notes создаются одним изменением; несовместимые protocol/config changes отражаются migration guide.

CI собирает CLI под Linux, macOS и Windows, проверяет startup/doctor на каждой ОС, генерирует checksums, подписывает artifacts и выполняет platform notarization/signing, где применимо. Затем для каждого публикуемого пакета выполняется:

```bash
dart pub publish --dry-run
```

Публикуемые пакеты не должны иметь path-зависимости: все внутренние dependencies переводятся на hosted version constraints, а lockfile и private workspace packages исключаются из publish content. Ошибка dry-run блокирует релиз.

## 14. Рабочая разбивка (WBS)

Каждая задача имеет единственный автоматический `Acceptance`. Неавтоматизируемые наблюдения переносятся в кривые роста фазы и не маскируются под тест. В Фазе 0 создаются ровно шесть пакетов начального v1: `alteri_one_protocol`, `alteri_one_platform`, `alteri_one_core`, `alteri_one_cli`, `alteri_one_memory`, `alteri_one_skills`. Пакеты `alteri_one_providers`, `alteri_one_mcp`, `alteri_one_subagents`, `alteri_one_hooks`, `alteri_one_tracing`, `alteri_one_sandbox`, `alteri_one_sdk` не создаются пустыми: соответствующая функциональность находится в `alteri_one_core`/`alteri_one_platform`, пока не доказано реальное дублирование. `alteri_one_sdk` остаётся delayed и материализуется в Фазе 5 только после появления второго независимого embed-потребителя.

### Фаза 0 — Walking skeleton

**Цель:** один детерминированный вертикальный срез `goal → provider → tool → result → finish`, доступный из нативного CLI и покрытый протокольными, unit-, contract- и integration-проверками.

- **0.1. Workspace Melos 8 и шесть пакетов.** Пакеты: `alteri_one_protocol`, `alteri_one_platform`, `alteri_one_core`, `alteri_one_cli`, `alteri_one_memory`, `alteri_one_skills`; `alteri_one_workspace` — только root manifest без library. Корневой `pubspec.yaml` содержит `workspace:` и секцию `melos:`; каждый пакет — `resolution: workspace`; `pubspec.lock` коммитится; `melos.yaml` и несуществующий `pubspec.workspaces.yaml` отсутствуют.

  Acceptance: `dart test test/workspace/workspace_contract_test.dart` завершается с кодом 0 и проверяет точный состав workspace, `resolution: workspace`, commit lock-файла и отсутствие легаси-конфигурации; тест `test/workspace/workspace_contract_test.dart` — `workspace uses pub workspaces and melos 8 configuration`.

- **0.2. Единые quality gates и CI.** Пакеты: workspace, все шесть v1-пакетов. CI выполняет `dart analyze --fatal-infos`, `dart test`, format-check и ту же цепочку на Linux, macOS и Windows; заданы отдельные test timeouts и coverage-конфигурация.

  Acceptance: `dart test test/ci/quality_gates_contract_test.dart` завершается с кодом 0 и проверяет наличие всех команд и матрицы `linux|macos|windows`; тест `test/ci/quality_gates_contract_test.dart` — `CI runs fatal analysis tests formatting on three operating systems`.

- **0.3. Архитектурная конституция, ADR и OSS-управление.** Пакеты: workspace/репозиторий. Фиксируются `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `CODEOWNERS`, `ARCHITECTURE.md`, конституция, threat model и ADR для workspace, протокола, тиров исполнения и web-таргета; задаётся канал сообщений об уязвимостях.

  Acceptance: `dart test test/governance/documentation_contract_test.dart` завершается с кодом 0 и проверяет наличие обязательных разделов, ADR и запрет Tier 2 без fail-closed; тест `test/governance/documentation_contract_test.dart` — `security and architecture records contain required decisions`.

- **0.4. Версионированный конверт и таксономия ошибок.** Пакет: `alteri_one_protocol`. `AlteriOneEnvelope` — sealed union request/response/notification/event с однозначным `result`/`error`; `proto` отделён от `moduleVersion`; таблица кодов из §4 проверяется типами и тестами.

  Acceptance: `melos exec --scope=alteri_one_protocol -- dart test test/protocol/envelope_contract_test.dart` завершается с кодом 0 и проверяет round-trip всех вариантов, отсутствие `id` у notification/event и mutually exclusive response; тест `test/protocol/envelope_contract_test.dart` — `sealed envelope variants round-trip and response is exclusive`.

- **0.5. Фрейминг и лимиты кадра.** Пакет: `alteri_one_protocol`. STDIO использует заголовок `Content-Length: <bytes>\r\n\r\n` и payload; `maxFrameBytes` по умолчанию равен 8 MiB; oversize и неполные кадры отклоняются, backpressure не unbounded.

  Acceptance: `melos exec --scope=alteri_one_protocol -- dart test test/protocol/framing_contract_test.dart` завершается с кодом 0 и проверяет разбор границ кадра, лимит 8 MiB и backpressure; тест `test/protocol/framing_contract_test.dart` — `Content-Length framing enforces eight MiB and propagates backpressure`.

- **0.6. Отмена, прогресс и handshake.** Пакет: `alteri_one_protocol`. Реализованы `$/cancelRequest`, `$/progress` и `core.initialize` с negotiation диапазона протокола, версии модуля, capabilities, limits и явной политикой refuse/degrade.

  Acceptance: `melos exec --scope=alteri_one_protocol -- dart test test/protocol/control_contract_test.dart` завершается с кодом 0 и проверяет correlation отмены, progress-события и handshake с отказом при несовместимой версии; тест `test/protocol/control_contract_test.dart` — `cancel progress and initialize negotiation are correlated`.

- **0.7. In-process транспорт.** Пакет: `alteri_one_protocol`. Транспорт использует тот же framed-envelope API, не зависит от `dart:io` и допускает детерминированные duplex-каналы для Tier 1.

  Acceptance: `melos exec --scope=alteri_one_protocol -- dart test test/transport/in_process_contract_test.dart` завершается с кодом 0 и проверяет request/response, cancellation notification и backpressure через in-process transport; тест `test/transport/in_process_contract_test.dart` — `in-process transport preserves protocol semantics`.

- **0.8. STDIO-транспорт.** Пакет: `alteri_one_protocol`. STDIO-адаптер корректно разделяет stdout протокола и stderr диагностики, переживает частичные reads и завершает дочерний канал без зависшего reader.

  Acceptance: `melos exec --scope=alteri_one_protocol -- dart test test/transport/stdio_contract_test.dart` завершается с кодом 0 и проверяет round-trip через реальные pipe streams с chunked input и диагностикой вне stdout; тест `test/transport/stdio_contract_test.dart` — `stdio transport handles partial frames and closes cleanly`.

- **0.9. Порты `alteri_one_platform`.** Пакет: `alteri_one_platform`. Определены и получили native-адаптеры `AlteriOneClock`, `AlteriOnePaths`, `AlteriOneHttpClient`, `AlteriOneStorage`, `AlteriOneConcurrency`; `dart:io` не проникает в `protocol` и `core`.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/platform/ports_contract_test.dart` завершается с кодом 0 и проверяет интерфейс, внедрение fake implementations и отсутствие `dart:io` в web-capable API; тест `test/platform/ports_contract_test.dart` — `platform ports are injectable and free of dart:io in public contracts`.

- **0.10. Детерминированные clock, id и `FakeProvider`.** Пакеты: `alteri_one_platform`, `alteri_one_core`. `AlteriOneClock` и генератор id внедряются во все трассы; `FakeProvider` скриптует ответы, считает usage, записывает transcript и не обращается к сети.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/fakes/fake_provider_contract_test.dart` завершается с кодом 0 и проверяет одинаковые id/время/usage при повторе scripted transcript и нулевые сетевые вызовы; тест `test/fakes/fake_provider_contract_test.dart` — `fake provider is deterministic and offline`.

- **0.11. Версионная схема профиля и `${ENV_VAR}`.** Пакет: `alteri_one_core`. Профиль имеет `apiVersion: alteri.one/v1`, `kind`, типизированную валидацию с путём поля, миграции, интерполяцию `${ENV_VAR}`, runtime paths и config precedence; секреты не принимаются из YAML. Для `persona.language` подключён `intl` без отдельной модели локализации протокола.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/profile/profile_contract_test.dart` завершается с кодом 0 и проверяет валидный YAML, migration path, field/line diagnostics, env-интерполяцию и приоритет sources; тест `test/profile/profile_contract_test.dart` — `profiles are versioned validated migrated and contain no literal secrets`.

- **0.12. Registry, event bus и dispatcher метода.** Пакет: `alteri_one_core`. Registry связывает capability с модулем, bus публикует typed events, dispatcher маршрутизирует `skill:`, `provider:` и namespace `core/*` по префиксу без изменения ядра при добавлении capability.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/core/registry_dispatch_contract_test.dart` завершается с кодом 0 и проверяет регистрацию двух модулей, prefix dispatch и подписку bus; тест `test/core/registry_dispatch_contract_test.dart` — `registry routes namespaced methods without core edits`.

- **0.13. OpenAI-compatible provider внутри core.** Пакет: `alteri_one_core`; отдельный `alteri_one_providers` не создаётся. Реализованы `package:http`-совместимый transport, streaming, usage и capability probe для tools/streaming/JSON mode/context window; capability matrix проверяется до запуска.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/provider/openai_compatible_contract_test.dart` завершается с кодом 0 и проверяет wire request, chunk assembly, usage и явный отказ при недостающей capability; тест `test/provider/openai_compatible_contract_test.dart` — `OpenAI-compatible provider streams usage and probes capabilities`.

- **0.14. Обязательные примитивы движка.** Пакет: `alteri_one_core`. `Deadline` распространяется вниз как `min(perCall, remaining)`, `CancelToken` имеет каскадный путь, `CostBudget` считает токены и USD, отдельно действуют `maxSteps` и детектор застоя.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/engine/control_primitives_contract_test.dart` завершается с кодом 0 и проверяет каждый предел на границе и комбинацию deadline+budget+cancel+step limit; тест `test/engine/control_primitives_contract_test.dart` — `nested calls never outlive parent deadline or budget`.

- **0.15. Детерминированный ReAct walking skeleton.** Пакет: `alteri_one_core`. Один прогон выполняет scripted provider turn, dispatch tool, применяет `ToolOutcome`, продолжает до terminal finish; v1 reasoning strategy — только ReAct.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/integration/walking_skeleton_test.dart` завершается с кодом 0 и проверяет полный transcript goal→tool→result→finish без реальной модели; тест `test/integration/walking_skeleton_test.dart` — `fake provider drives one complete walking skeleton`.

- **0.16. Детерминированный test tier, transcript и replay.** Пакеты: `alteri_one_core`, `alteri_one_cli`. Здесь test tier не путается с execution Tier 1: unit, contract и integration tests разделены; каждый прогон пишет JSONL transcript с `traceId`, redaction и SHA-256; replay воспроизводит tool outcomes и usage без вызова модели.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/transcript/replay_integration_test.dart` завершается с кодом 0 и проверяет побайтно стабильный replay, redaction и digest при фиксированных clock/id; тест `test/transcript/replay_integration_test.dart` — `recorded transcript replays without provider access`.

- **0.17. Минимальный CLI REPL и graceful shutdown.** Пакет: `alteri_one_cli`. REPL загружает профиль, принимает goal, печатает streaming/progress и результат; SIGINT выполняет cancel → drain → flush state → exit code, не оставляя повреждённый transcript.

  Acceptance: `melos exec --scope=alteri_one_cli -- dart test test/integration/repl_integration_test.dart` завершается с кодом 0 и проверяет scripted REPL-сессию и корректное прерывание во время tool call; тест `test/integration/repl_integration_test.dart` — `REPL runs fake profile and drains cancellation`.

- **0.18. `alteri_one doctor`.** Пакет: `alteri_one_core`, вызывается из `alteri_one_cli`. Команда валидирует YAML, paths, permissions, свободное место, provider capabilities, версии и digest transcript/profile, объясняет failed module load; диагностика содержит файл, строку и path до поля.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/doctor/doctor_contract_test.dart` завершается с кодом 0 и проверяет успешный exit code для исправной конфигурации и точные diagnostics для сломанной; тест `test/doctor/doctor_contract_test.dart` — `doctor validates config providers paths and digests`.

- **0.19. Генератор Tier 1 модуля.** Пакет: `alteri_one_cli`; результат подключается к `alteri_one_core`. `init module` создаёт package scaffold, versioned manifest, typed capabilities, contract tests и codegen-регистрацию; dynamic import и runtime scan отсутствуют.

  Acceptance: `melos exec --scope=alteri_one_cli -- dart test test/scaffolds/init_module_integration_test.dart` завершается с кодом 0 и проверяет генерацию, build и регистрацию модуля только через generated registry; тест `test/scaffolds/init_module_integration_test.dart` — `generated trusted module registers without runtime loading`.

**Критерий фазы 0 — кривая роста:**

1. `[автоматизируемо]` Один и тот же scripted transcript даёт идентичные result, usage, id и digest на Linux, macOS и Windows.
2. `[автоматизируемо]` REPL проходит `goal → tool → ToolOutcome → finish`, а `doctor` обнаруживает ошибочный `apiVersion`, неизвестное поле и недостающую provider capability.
3. `[вручную]` Reviewer за фиксированный сценарий проверяет читаемость streaming/progress и отсутствие ложного ощущения зависания; этот пункт не является `Acceptance`.

### Фаза 1 — Память и политика

**Цель:** детерминированно сохранять версионированную память и ограничивать authority до попадания данных в контекст, не позволяя untrusted provenance повышаться до trusted.

- **1.1. Коллекции `hive_ce`.** Пакет: `alteri_one_memory`. Реализованы `sessions`, `messages`, `facts`, `episodes`, `preferences`, `artifacts`; `hive_ce` скрыт за `AlteriOneStorage`, миграции и открытие проверяются на чистой временной директории.

  Acceptance: `melos exec --scope=alteri_one_memory -- dart test test/storage/hive_ce_contract_test.dart` завершается с кодом 0 и проверяет создание, reopen и round-trip всех шести типизированных коллекций; тест `test/storage/hive_ce_contract_test.dart` — `all v1 memory collections survive reopen`.

- **1.2. `MemoryRecord`, provenance, TTL и confidence.** Пакет: `alteri_one_memory`. Sealed records различают user-stated, model-inferred и tool-observed данные; `ttl`, `confidence`, `createdAt`, `lastSeenAt`, conflict history и `supersededBy` имеют строгую валидацию.

  Acceptance: `melos exec --scope=alteri_one_memory -- dart test test/records/memory_record_contract_test.dart` завершается с кодом 0 и проверяет диапазоны confidence, expiry на injected clock и запрет молчаливого перезаписывания конфликта; тест `test/records/memory_record_contract_test.dart` — `memory records preserve provenance TTL and conflict lineage`.

- **1.3. Delete, export, forget и retention.** Пакеты: `alteri_one_memory`, `alteri_one_cli`. Поддержаны точечный delete, полный profile export, forget с очисткой связанных records/artifacts и retention по injected clock; JSON export не содержит секреты.

  Acceptance: `melos exec --scope=alteri_one_memory -- dart test test/privacy/delete_export_forget_integration_test.dart` завершается с кодом 0 и проверяет удаление из индекса и storage, воспроизводимый export и отсутствие removed data после forget; тест `test/privacy/delete_export_forget_integration_test.dart` — `delete export and forget remove or reveal only selected data`.

- **1.4. Token-triggered compaction.** Пакет: `alteri_one_memory`, интеграция с `alteri_one_core`. Триггер использует проверенный provider usage, а не число сообщений; операция детерминирована на `FakeProvider`, сохраняет факты с исходным provenance и не превращает untrusted summary в trusted fact.

  Acceptance: `melos exec --scope=alteri_one_memory -- dart test test/compaction/compaction_integration_test.dart` завершается с кодом 0 и проверяет порог по usage, golden transcript и provenance после compaction; тест `test/compaction/compaction_integration_test.dart` — `compaction triggers on usage and preserves trust labels`.

- **1.5. Policy engine `deny > confirm > allow`.** Пакет: `alteri_one_core`. Решение — sealed `Allowed | NeedsApproval | Denied`; deny имеет приоритет, policy layers имеют явный precedence. `Denied` и declined approval возвращаются модели как `ToolOutcome`, а не завершают весь прогон.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/policy/policy_engine_integration_test.dart` завершается с кодом 0 и проверяет precedence, redaction prompt и продолжение scripted run после deny/decline; тест `test/policy/policy_engine_integration_test.dart` — `deny wins and denied tool outcomes remain model-visible`.

- **1.6. Tool-result budgeting.** Пакеты: `alteri_one_core`, `alteri_one_memory`. Это главный дешёвый барьер раздувания context до дорогой compaction: большой результат обрезается или выгружается в `ArtifactRecord`; модель получает typed pointer, retrieval требует policy и не возвращает весь blob молча.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/context/tool_result_budget_integration_test.dart` завершается с кодом 0 и проверяет лимит переданных токенов, round-trip artifact и policy-gated retrieval; тест `test/context/tool_result_budget_integration_test.dart` — `large tool output becomes a bounded artifact pointer`.

- **1.7. Первый Tier 1 trusted-модуль.** Пакеты: `alteri_one_core`, генерируемый пакет из `alteri_one_cli`. Модуль линкуется в AOT-бинарь, регистрируется generated registry и может выполняться в изоляте только для локализации ошибок; security boundary не заявляется.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/modules/trusted_module_integration_test.dart` завершается с кодом 0 и проверяет generated registration, вызов capability и переживание ядра обычной ошибкой модуля; тест `test/modules/trusted_module_integration_test.dart` — `trusted module is static and isolate is not a security boundary`.

**Критерий фазы 1 — кривая роста:**

1. `[автоматизируемо]` Restart процесса сохраняет sessions/messages/facts/episodes/preferences/artifacts, а expired/forgotten записи отсутствуют.
2. `[автоматизируемо]` Golden eval на `FakeProvider` подтверждает deny/confirm/allow precedence, продолжение после отказа и bounded tool result.
3. `[вручную]` Пользователь проверяет читаемость export и предсказуемость confirm prompts; ручная оценка не заменяет contract tests.

### Фаза 2 — Skill-паки и MCP-клиент

**Цель:** дать marketplace безопасный Tier 0-старт и подключить внешние MCP capabilities без превращения untrusted content в authority.

- **2.1. Формат Skill Pack.** Пакет: `alteri_one_skills`. Формат и валидатор выровнены с открытой Agent Skills specification (`agentskills.io`) и Dart package skills; собственный проприетарный container format не вводится.

  Acceptance: `melos exec --scope=alteri_one_skills -- dart test test/format/agent_skills_conformance_test.dart` завершается с кодом 0 и проверяет принятие валидных external fixtures и диагностируемое отклонение несовместимых; тест `test/format/agent_skills_conformance_test.dart` — `skill pack parser matches Agent Skills and Dart package skills contracts`.

- **2.2. Discovery и применение data-only Skill Pack.** Пакет: `alteri_one_skills`. Загрузчик находит `SKILL.md` и ресурсы, проверяет manifest/digest, связывает pack с профилем и не исполняет находящиеся в нём scripts; Tier 0 не регистрирует authority.

  Acceptance: `melos exec --scope=alteri_one_skills -- dart test test/runtime/skill_pack_integration_test.dart` завершается с кодом 0 и проверяет установку/применение data-only pack без изменения core и отсутствие запуска scripts; тест `test/runtime/skill_pack_integration_test.dart` — `skill pack applies as data without gaining capabilities`.

- **2.3. Host-side provenance labels.** Пакеты: `alteri_one_core`, `alteri_one_skills`. `trusted_user`, `untrusted_web`, `untrusted_email`, `untrusted_tool_output`, `private_data`, `secret` назначаются детерминированным host-кодом на границе входа и переживают transport/serialization.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/provenance/content_labels_contract_test.dart` завершается с кодом 0 и проверяет неизменность метки через protocol boundary и запрет label, назначаемой моделью; тест `test/provenance/content_labels_contract_test.dart` — `provenance is host-assigned and immutable across transport`.

- **2.4. Границы недоверенного контента.** Пакеты: `alteri_one_core`, `alteri_one_skills`, внутренний MCP-адаптер. Данные и инструкции разделяются; untrusted content не авторизует tool, MCP instructions/tool descriptions не становятся системным промптом, capabilities остаются узкими и типизированными.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/provenance/untrusted_content_integration_test.dart` завершается с кодом 0 и проверяет что injected skill/MCP text не расширяет registry и не обходит policy; тест `test/provenance/untrusted_content_integration_test.dart` — `untrusted instructions cannot grant authority`.

- **2.5. Выбор MCP client adapter.** Пакет: `alteri_one_core`; `alteri_one_mcp` не создаётся без дублирования. Сравниваются `dart_mcp` и `mcp_dart` на одинаковом contract fixture ревизии `2026-07-28`; выбор фиксируется ADR, а не предполагается по имени пакета.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/mcp/client_adapter_contract_test.dart` завершается с кодом 0 и проверяет прохождение выбранным adapter единого initialize/tools/resources/prompts fixture; тест `test/mcp/client_adapter_contract_test.dart` — `selected MCP client implements revision 2026-07-28 fixture`.

- **2.6. MCP client в core.** Пакет: `alteri_one_core`; выделение `alteri_one_mcp` допускается только при доказанном втором consumer. Реализованы tools/resources/prompts, correlation, cancellation, progress, frame limit, diagnostics и явная version negotiation; server mode отсутствует до Фазы 4.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/mcp/mcp_client_integration_test.dart` завершается с кодом 0 и проверяет вызов tools/resources/prompts через локальный test server с cancel и oversize rejection; тест `test/mcp/mcp_client_integration_test.dart` — `core MCP client maps protocol lifecycle without exposing server instructions`.

**Критерий фазы 2 — кривая роста:**

1. `[автоматизируемо]` Валидный Tier 0 pack устанавливается, применяется и удаляется без изменения `alteri_one_core`; его scripts не получают запуск.
2. `[автоматизируемо]` Fixture prompt injection и tool poisoning сохраняют untrusted label и не создают capability.
3. `[автоматизируемо]` MCP client проходит initialize и чтение tools/resources/prompts на ревизии `2026-07-28`; выбранная библиотека и отклонения записаны в ADR.

### Фаза 3 — Недоверенные модули (Tier 2)

**Цель:** исполнять только precompiled Tier 2 AOT-exe вне процесса ядра и на Linux обеспечивать OS sandbox, resource limits и brokers; на любой неподдерживаемой конфигурации отказать.

- **3.1. Manifest, digest, подпись и capability intersection.** Пакеты: `alteri_one_platform`, `alteri_one_core`. Tier 2 manifest versioned; digest и подпись проверяются до запуска, executable берётся из доверенного registry, requested capabilities пересекаются с profile/user/admin/deployment policy. Подпись доказывает происхождение, не безопасность поведения.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/tier2/artifact_verification_integration_test.dart` завершается с кодом 0 и проверяет запуск подписанного digest и отказ для tampered, unsigned и over-privileged артефактов; тест `test/tier2/artifact_verification_integration_test.dart` — `Tier 2 verifies provenance and policy before process creation`.

- **3.2. Out-of-process launcher.** Пакет: `alteri_one_platform`. Запуск выполняется с `includeParentEnvironment: false`, минимальным environment, отдельным tmpfs workspace и STDIO/unix-socket transport; runtime dynamic loading отсутствует.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/tier2/launcher_scrub_contract_test.dart` завершается с кодом 0 и проверяет полный env allowlist, cwd и protocol handshake precompiled AOT fixture; тест `test/tier2/launcher_scrub_contract_test.dart` — `launcher excludes parent environment and starts only verified executable`.

- **3.3. Linux OS sandbox.** Пакет: `alteri_one_platform`. Поддерживается backend `bwrap`/`nsjail`; применяются cgroup v2 `memory.max`, `cpu.max`, `pids.max`, seccomp и network namespace без прямой сети. Ошибка подготовки sandbox не допускает fallback.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/tier2/linux_sandbox_contract_test.dart` завершается с кодом 0 и проверяет параметры обоих backend, cgroup limits и fail-closed preflight; тест `test/tier2/linux_sandbox_contract_test.dart` — `Linux sandbox applies cgroup seccomp and no-network controls`.

- **3.4. Kill process tree и каскадная отмена.** Пакеты: `alteri_one_platform`, `alteri_one_core`. Timeout/CancelToken завершает всю группу или cgroup, а не только launcher PID; descendants reap-ятся, core продолжает работу.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/tier2/process_group_kill_integration_test.dart` завершается с кодом 0 и проверяет termination fork bomb fixture и отсутствие живых descendants после timeout; тест `test/tier2/process_group_kill_integration_test.dart` — `cancellation kills the complete sandbox process group`.

- **3.5. Secret broker и opaque capability id.** Пакеты: `alteri_one_core`, `alteri_one_platform`. Секреты отсутствуют в env, argv, файлах и protocol frames; модуль получает opaque capability id, broker проверяет policy и operation и подставляет credential только на стороне брокера.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/tier2/secret_broker_integration_test.dart` завершается с кодом 0 и проверяет отсутствие raw secret в frames/process metadata и успех только авторизованной operation с opaque id; тест `test/tier2/secret_broker_integration_test.dart` — `secret never crosses module boundary in plaintext`.

- **3.6. Network broker.** Пакеты: `alteri_one_core`, `alteri_one_platform`. Прямой DNS/socket/HTTP закрыт; разрешённая операция проходит через broker, который проверяет destination, method, redirect, size, credentials и rate limit. Default — deny.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/tier2/network_broker_integration_test.dart` завершается с кодом 0 и проверяет блокировку direct/raw socket и allowlisted broker request; тест `test/tier2/network_broker_integration_test.dart` — `network is denied except brokered policy operations`.

- **3.7. Adversarial-набор Tier 2.** Пакеты: `alteri_one_platform`, `alteri_one_core`, adversarial fixtures. Проверяются чтение env, `exit(0)`, raw socket, прямой `HttpClient`, `DynamicLibrary.open`, fork, превышение memory, frame flood, получение URI VM Service и prompt injection в result; ожидаются deny/termination, живое core и недоступные секреты.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/tier2/adversarial_suite_integration_test.dart` завершается с кодом 0 и проверяет все десять adversarial cases и их раздельные expected outcomes; тест `test/tier2/adversarial_suite_integration_test.dart` — `all Tier 2 escape and resource attacks fail closed`.

- **3.8. Платформенная политика fail-closed.** Пакет: `alteri_one_platform`, проверка CI на трёх ОС. macOS и Windows до появления supervisor-а запускают Tier 0/1, но Tier 2 завершают явным refusal; web Tier 2 также запрещён. Изоляция не заменяет process sandbox.

  Acceptance: `melos exec --scope=alteri_one_platform -- dart test test/tier2/platform_policy_contract_test.dart` завершается с кодом 0 и проверяет refusal до process creation на macOS/Windows/web и поддержку только на настроенном Linux; тест `test/tier2/platform_policy_contract_test.dart` — `Tier 2 refuses unsupported platforms without fallback`.

**Критерий фазы 3 — кривая роста:**

1. `[автоматизируемо]` На Linux adversarial fixture не читает env/secret, не получает сеть, не выживает после kill и не роняет core.
2. `[автоматизируемо]` Tampered artifact и request capability сверх policy не создают процесс; подписанный разрешённый artifact проходит handshake.
3. `[вручную]` Security reviewer проверяет конфигурацию bwrap/nsjail, cgroup v2 и seccomp на поддерживаемой Linux-версии; ручное подтверждение наличия environment prerequisites не заменяет automated adversarial suite.

### Фаза 4 — Автономность

**Цель:** добавить ограниченную делегацию, developer workflow и MCP server mode только после работающего Tier 2; новые authority всегда проходят общий policy.

- **4.1. `ReasoningStrategy` с единственной v1-реализацией ReAct.** Пакет: `alteri_one_core`. Интерфейс отделяет стратегию от engine; `plan-execute` и `recursive` не реализуются и не маскируются под profile aliases.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/reasoning/strategy_registry_contract_test.dart` завершается с кодом 0 и проверяет единственную зарегистрированную ReAct-стратегию и отказ для отсутствующих стратегий; тест `test/reasoning/strategy_registry_contract_test.dart` — `v1 exposes only ReAct`.

- **4.2. Subagents с общими лимитами.** Пакет: `alteri_one_core`; `alteri_one_subagents` не создаётся без дублирования. Parent и children используют общий `CostBudget`, depth, concurrency и per-child trace; отсутствие allocation даёт явный `BudgetExceeded`.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/subagents/shared_limits_integration_test.dart` завершается с кодом 0 и проверяет суммарные tokens/USD, max depth и concurrency для дерева subagents; тест `test/subagents/shared_limits_integration_test.dart` — `subagent tree cannot multiply parent budget or depth`.

- **4.3. Каскадная отмена subagents.** Пакеты: `alteri_one_core`, `alteri_one_platform`. Отмена parent проходит child → Tier 1 transport → Tier 2 process group; in-flight tool outcomes не запускают новых шагов.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/subagents/cascade_cancel_integration_test.dart` завершается с кодом 0 и проверяет отсутствие новых model/tool calls после cancellation; тест `test/subagents/cascade_cancel_integration_test.dart` — `parent cancellation reaches every descendant and sandbox group`.

- **4.4. Выбор модели для subagents.** Пакет: `alteri_one_core`. Профиль может назначить дешёвую совместимую модель по умолчанию; capability probe и общий budget применяются до запуска, скрытая смена модели запрещена.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/subagents/model_selection_integration_test.dart` завершается с кодом 0 и проверяет выбор cheapest-compatible из явной цепочки и отказ при отсутствии tools/streaming; тест `test/subagents/model_selection_integration_test.dart` — `subagent model respects profile capability and cost order`.

- **4.5. Developer-режим.** Пакеты: `alteri_one_core`, `alteri_one_cli`, Tier 0/Tier 1 packs. Репозиторный context, тестовые команды и dev capabilities выдаются developer profile; destructive git/file/process operations проходят confirm/deny policy и не обходят confirmation в `--headless`.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/profiles/developer_policy_integration_test.dart` завершается с кодом 0 и проверяет доступность разрешённых dev capabilities и запрет destructive operation при decline; тест `test/profiles/developer_policy_integration_test.dart` — `developer profile is broader but still policy-bound`.

- **4.6. MCP server mode и mapping layer.** Пакет: `alteri_one_core`; `alteri_one_mcp` выделяется только при реальном втором adapter consumer. AlteriOne capabilities экспортируются как MCP tools/resources/prompts ревизии `2026-07-28`; mapping сохраняет policy, redaction, deadlines и cancellation.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/mcp/mcp_server_mapping_integration_test.dart` завершается с кодом 0 и проверяет schema mapping, deny/deadline propagation и отказ неизвестной capability; тест `test/mcp/mcp_server_mapping_integration_test.dart` — `MCP server exposes only mapped policy-checked capabilities`.

**Критерий фазы 4 — кривая роста:**

1. `[автоматизируемо]` Дерево subagents укладывается в общий token/USD/depth/concurrency budget и полностью отменяется одним signal.
2. `[автоматизируемо]` MCP client из Фазы 2 вызывает server mode Фазы 4, а denied operation остаётся denied через оба слоя.
3. `[вручную]` Reviewer проходит короткий developer workflow и проверяет, что подтверждения понятны, а отказ не оставляет частично применённого side effect; side-effect contract дополнительно проверяется тестом.

### Фаза 5 — SDK и фронтенды

**Цель:** после доказанного embed-дублирования выпустить SDK, отполировать native CLI и добавить Flutter app/web без переноса v1 на web.

- **5.1. Решение monolith или thin UI для web.** Пакеты: `alteri_one_platform`, ADR. В начале Фазы 5 сравниваются full core в web bundle и тонкий UI с удалённым/встроенным core; v1 остаётся native CLI. ADR обязано учитывать storage, auth, streaming, cancellation и отсутствие native isolates/Tier 2.

  Acceptance: `dart test test/architecture/frontend_decision_contract_test.dart` завершается с кодом 0 и проверяет ровно одно выбранное решение, owner и обязательные trade-offs; тест `test/architecture/frontend_decision_contract_test.dart` — `web ADR selects one supported architecture and records constraints`.

- **5.2. Materialization gate для `alteri_one_sdk`.** Пакет: `alteri_one_sdk` из отложенного списка; создаётся только при втором независимном embed consumer. Публичный facade re-export-ит стабильные API, примеры не импортируют internal paths, breaking changes проверяются contract tests.

  Acceptance: `melos exec --scope=alteri_one_sdk -- dart test test/sdk/public_api_contract_test.dart` завершается с кодом 0 и проверяет re-export surface и запуск двух embed examples без internal imports; тест `test/sdk/public_api_contract_test.dart` — `SDK examples depend only on public API`.

- **5.3. CLI polish и машинный интерфейс.** Пакет: `alteri_one_cli`. Реализованы `--profile`, `--dry-run`, `--json`, `--headless`, единые exit codes, явная обработка approval в headless и стабильный stdout contract.

  Acceptance: `melos exec --scope=alteri_one_cli -- dart test test/cli/flags_exit_codes_integration_test.dart` завершается с кодом 0 и проверяет flags, JSON-only output и documented exit code для success/policy/cancel/timeout; тест `test/cli/flags_exit_codes_integration_test.dart` — `CLI flags are scriptable and headless cannot hang for approval`.

- **5.4. `why` и replay CLI.** Пакеты: `alteri_one_cli`, `alteri_one_core`. `alteri_one why <traceId>` показывает decision timeline, policy, usage, cost, Deadline, budget и provenance с redaction; replay остаётся read-only.

  Acceptance: `melos exec --scope=alteri_one_cli -- dart test test/cli/why_replay_integration_test.dart` завершается с кодом 0 и проверяет полную correlation trace и отсутствие повторного side effect при replay; тест `test/cli/why_replay_integration_test.dart` — `why explains a redacted replayable run`.

- **5.5. Flutter app.** Пакет: `applications/app` поверх публичного API; DI-фреймворк выбирается только здесь. App использует stream/state из core, не дублирует engine и соблюдает те же cancellation/session boundaries, что и CLI.

  Acceptance: `flutter test test/app_contract_test.dart` из `applications/app` завершается с кодом 0 и проверяет запуск scripted run, streaming UI и отмену без прямого engine fork; тест `test/app_contract_test.dart` — `Flutter app renders core stream and cancellation`.

- **5.6. Web-реализация `AlteriOneStorage`.** Пакет: `alteri_one_platform`. Выбранная web architecture получает IndexedDB/иной browser storage adapter, versioned schema, TTL и quota/error handling через `package:web`; native `dart:io` не импортируется.

  Acceptance: `flutter test test/web_storage_contract_test.dart` из `applications/web` завершается с кодом 0 и проверяет schema migration, TTL и browser quota/error path web adapter; тест `test/web_storage_contract_test.dart` — `web storage is versioned and contains no dart:io`.

- **5.7. Web Workers вместо isolates.** Пакет: `alteri_one_platform`. `AlteriOneConcurrency` получает worker-backed реализацию, ограничение concurrency, progress и cooperative cancellation; Tier 2 и OS sandbox на web объявлены unavailable.

  Acceptance: `flutter test test/web_concurrency_contract_test.dart` из `applications/web` завершается с кодом 0 и проверяет bounded workers, cancellation и explicit refusal Tier 2; тест `test/web_concurrency_contract_test.dart` — `web concurrency uses workers and rejects native isolation claims`.

- **5.8. Web UI и end-to-end boundary.** Пакет: `applications/web` поверх `alteri_one_sdk`/public core API. UI не получает raw secret, не создаёт native capability и сохраняет transcript/policy semantics выбранной архитектуры.

  Acceptance: `flutter test test/web_app_integration_test.dart` из `applications/web` завершается с кодом 0 и проверяет goal→stream→policy outcome→finish в выбранной архитектуре; тест `test/web_app_integration_test.dart` — `web app preserves core control semantics`.

**Критерий фазы 5 — кривая роста:**

1. `[автоматизируемо]` Внешний fixture запускает тот же loop через публичный API, не импортируя internal packages; два consumer-а обосновывают materialization SDK.
2. `[автоматизируемо]` CLI одинаково выдаёт human/JSON/headless результат и одинаковые exit codes для одного transcript.
3. `[вручную]` UX-reviewer проверяет app/web session, reconnect/cancel и понятность policy prompts; недоступные Tier 1/Tier 2 возможности отображаются явно, а не через скрытый fallback.

### Фаза 6 — Экосистема и релиз

**Цель:** выпустить проверяемую ecosystem/релизную инфраструктуру для Tier 0 packs и подписанных precompiled Tier 2 modules, не превращая OSS-релиз в unverifiable installer.

- **6.1. Marketplace и проверяемая установка.** Пакеты: `alteri_one_cli`, `alteri_one_skills`, внутренний Tier 2 host. Marketplace начинается с Tier 0 skill-packs; module item содержит tier, digest, signature и manifest, устанавливает только precompiled AOT-exe, а policy проверяется до запуска.

  Acceptance: `melos exec --scope=alteri_one_cli -- dart test test/marketplace/install_verification_integration_test.dart` завершается с кодом 0 и проверяет установку Tier 0, отказ tampered Tier 2 и запуск только verified policy-approved executable; тест `test/marketplace/install_verification_integration_test.dart` — `marketplace never installs unverified code`.

- **6.2. Публичная документация и examples.** Пакеты: workspace, все publishable packages. Документация покрывает profiles, API/embed, transport/frame, skills, Tier 1/2, policy, memory/privacy, MCP, release и troubleshooting; примеры компилируются CI.

  Acceptance: `dart test test/docs/documentation_examples_contract_test.dart` завершается с кодом 0 и проверяет наличие всех разделов, валидные internal links и компиляцию зафиксированных examples; тест `test/docs/documentation_examples_contract_test.dart` — `documentation links and examples match the released API`.

- **6.3. Feedback loop для eval-набора.** Пакет: `alteri_one_core`. thumbs up/down и corrected outcome сохраняются как versioned eval cases с consent/redaction; real-model eval запускается вручную или по расписанию, не блокируя детерминированные unit/contract/integration tests.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/eval/feedback_corpus_contract_test.dart` завершается с кодом 0 и проверяет обезличивание, provenance feedback, version bump и отсутствие автоматического доверия к model-generated expected result; тест `test/eval/feedback_corpus_contract_test.dart` — `feedback becomes a reviewed versioned eval case`.

- **6.4. OpenTelemetry поверх transcript.** Пакет: `alteri_one_core`; `alteri_one_tracing` не создаётся без дублирования. Adapter использует `opentelemetry` 0.18.x, помеченный как community/pre-1.0 с Beta traces; экспорт opt-in, off by default, span создаётся из transcript и не меняет replay.

  Acceptance: `melos exec --scope=alteri_one_core -- dart test test/telemetry/otel_over_transcript_integration_test.dart` завершается с кодом 0 и проверяет opt-in span tree, redaction и побайтно неизменный transcript при выключенной телеметрии; тест `test/telemetry/otel_over_transcript_integration_test.dart` — `OTel is optional and derived from transcript`.

- **6.5. Coordinated versioning и changelog.** Пакеты: workspace и publishable packages. `melos version` соблюдает DAG, публичные пакеты не имеют path-only dependencies, version bump и changelog section проверяются автоматически.

  Acceptance: `melos run release:version-check` завершается с кодом 0 и проверяет semver по workspace DAG, наличие changelog entry и допустимость публикации; тест `test/release/versioning_contract_test.dart` — `coordinated versions follow package dependencies and changelog`.

- **6.6. Бинари под три ОС.** Пакеты: `alteri_one_cli`, release pipeline. Native CLI собирается и smoke-test-ится на Linux, macOS и Windows; проверяются version, startup, embedded assets, checksum и воспроизводимый manifest.

  Acceptance: `melos run release:artifact-check` завершается с кодом 0 и проверяет три platform artifacts, manifest и checksum; тест `test/release/artifact_contract_test.dart` — `release matrix contains verified binaries for three operating systems`.

- **6.7. Подпись и notarization pipeline.** Пакеты: workspace/release pipeline; `alteri_one_mcp` и документационные пакеты в signing не участвуют. Артефакты подписываются platform-native tooling; macOS notarization и Windows signature проверяются до публикации; key rotation/revocation и provenance manifest задокументированы.

  Acceptance: `melos run release:signature-check` завершается с кодом 0 и проверяет dry-run signing manifest, verification step и policy для macOS/Windows; тест `test/release/signature_contract_test.dart` — `release pipeline requires verifiable platform signatures`.

- **6.8. Release CI и pub dry-run.** Пакеты: все publishable v1 packages. Полный analyze/test/format/build/matrix выполняется на candidate tag; каждый публикуемый пакет проходит `dart pub publish --dry-run` без path-dependencies и лишних файлов.

  Acceptance: `melos run release:publish-dry-run` завершается с кодом 0 и проверяет dry-run каждого publishable package и публикационный manifest; тест `test/release/publish_dry_run_contract_test.dart` — `all publishable packages pass pub dry-run from release workspace`.

**Критерий фазы 6 — кривая роста:**

1. `[автоматизируемо]` Чистый checkout проходит release pipeline, создаёт три подписанных бинаря, проверяет checksum и проходит `dart pub publish --dry-run` для publishable packages.
2. `[автоматизируемо]` Marketplace fixture устанавливает Tier 0 pack и подписанный Tier 2 module; tampered/unsigned/over-privileged item отклоняется до запуска.
3. `[вручную]` Release owner подтверждает notarization/credential-dependent steps, changelog, migration notes и `SECURITY.md`; эти credential gates не выдаются за локально проверенные acceptance.

## 15. Решения по спорным вопросам

Исходные открытые вопросы закрыты следующим образом.

| Вопрос | Решение | Обоснование |
|---|---|---|
| Melos или pub workspaces? | Оба механизма. Pub workspaces связывают локальные пакеты; Melos 8.9 оркестрирует scripts, versioning и release. Конфигурация Melos находится в корневом `pubspec.yaml`; `melos.yaml` не используется. | Dart 3.13 поддерживает workspaces и glob-пути. Один только Melos сохранял бы лишний linking-слой, а один только pub не заменяет orchestration. |
| Flutter для app и web? | Да, Flutter. Конкретный DI/state-фреймворк до Фазы 5 не выбирается; состояние может оставаться stream/state в core при тонком UI. | App и web получают единый Dart/UI стек, а преждевременная привязка к DI усложняет web-решение без выигрыша для CLI v1. |
| Web: monolith или тонкий UI? | Прежнее «решено: monolith» отменено. v1 — только native CLI. Web переносится в Фазу 5, где ADR выбирает full core в browser bundle либо тонкий UI; оба варианта обязаны учитывать storage и workers. | `dart:io` и native isolates отсутствуют. Core требует platform ports, browser storage и замены concurrency; Tier 2 на web не переносится. |
| Hive и схема памяти? | `hive_ce`, не `hive`. Коллекции: `sessions`, `messages`, `facts`, `episodes`, `preferences`, `artifacts`; vector recall остаётся за `VectorIndex` вне v1. | Оригинальный `hive` несовместим с Dart 3.13 и не имеет ANN. `hive_ce` решает native persistence, но не превращает KV в vector DB. |
| Sandbox через isolate и limits? | Нет. Модель заменена тремя тирами: Tier 0 Skill Pack, Tier 1 Trusted Module, Tier 2 Untrusted Module. Isolate — локализация ошибок/CPU, не security boundary. | Изолят разделяет память процесса и не блокирует env, FFI, raw sockets, process API, `exit(0)` и VM Service. Tier 2 требует отдельного процесса и OS controls. |
| Tracing? | В Фазе 0 — transcript, `traceId` и JSONL с redaction/replay. В Фазе 6 — OTel поверх transcript через community/pre-1.0 `opentelemetry` 0.18.x, Beta traces. | Transcript отвечает на вопрос «почему агент поступил именно так», а OTel — на распределённую телеметрию; ранняя OTel-зависимость не оправдана. |

### 15.1. Что осталось открытым

| Вопрос | Эксперимент и критерий выхода | Фаза |
|---|---|---|
| Зрелость `local_hnsw` и качество recall | На версионированном корпусе из sessions/facts измерить recall@k против lexical baseline, p50/p95 insert/query, размер индекса, corruption recovery и web/native build. В v1 индекс не включать, пока не подтверждены воспроизводимость и прирост качества. | После v1, research-задача в Фазе 6; не блокирует релиз. |
| `dart_mcp` 0.5.2 против `mcp_dart` | Собрать один contract fixture ревизии `2026-07-28`: initialize, tools/resources/prompts, progress, cancellation, error mapping, framing limit и reconnect. Сравнить API completeness, изоляцию ошибок и стоимость adapter; выбрать по тестам и ADR. | 2 |
| Нужен ли browser `AlteriOneStorage` для выбранной web-архитектуры | Провести prototype IndexedDB с migrations, TTL, quota, вкладками/concurrency и replay; для remote-core хранить только явный local cache, если offline/local-first нужен. Решение фиксируется в web ADR. | 5 |
| Поведение `freezed` 4.x с records/unions и AOT | На pinned `build_runner` проверить generated sealed union, named/positional records, exhaustive switch, JSON discriminator, deterministic output и AOT compile. При drift закрепить fixtures и regression tests либо изолировать generated types. | 0 |
| Достаточны ли `bwrap`/`nsjail` для precompiled Dart AOT child | Проверить mount/network namespace, inherited descriptors, Unix-socket broker, multi-process tree, cgroup v2 inheritance и seccomp profile на поддерживаемых дистрибутивах. Backend без доказанного preflight считается unavailable, а не ослабляет режим. | 3 |
| Где хранить trust roots и как ротировать подписи | Определить offline root, release/intermediate keys, revocation list, key ID в manifest, cross-OS artifact identity и процедуру compromised key. Проверить positive/negative/expired/revoked fixtures; подпись остаётся проверкой происхождения, не поведения. | 3 |
| Как одновременно выразить Agent Skills и Dart package skills | Проверить все зафиксированные metadata/manifest fields, path layout, resource references и правила discovery; определить минимальное lossless mapping без собственного контейнера. Несовместимые поля диагностировать, а не игнорировать. | 2 |

## 16. Стартовые команды

Melos 8 не инициализируется legacy-командой. Root workspace создаётся вручную, а package manifests получают `resolution: workspace`.

```bash
dart pub global activate melos
```

Минимальный корневой `pubspec.yaml`:

```yaml
name: alteri_one_workspace
publish_to: none

environment:
  sdk: '>=3.13.0 <4.0.0'

workspace:
  - packages/*
  - applications/*
  - sdk/*

dev_dependencies:
  melos: ^8.9.0

melos:
  scripts:
    test: melos exec --fail-fast -- dart test
    analyze: melos exec -- dart analyze --fatal-infos
    generate: melos exec --depends-on="^build" -- dart run build_runner build
    build-cli: melos exec --scope="alteri_one_cli" -- dart build cli
    doctor: dart run alteri_one_core doctor
```

Корневой lock-файл `pubspec.lock` коммитится. Каждый пакет workspace начинается с:

```yaml
name: alteri_one_core
publish_to: none
resolution: workspace

environment:
  sdk: '>=3.13.0 <4.0.0'
```

Разрешение зависимостей и линковка локальных packages выполняются самим `dart pub get` через pub workspaces:

```bash
dart pub get
```

`melos bootstrap` можно запускать как единую orchestration-команду, но он больше не является обязательным prerequisite для linking локальных packages. Его роль — запуск общих hooks/scripts перед batch-операциями; pub workspaces уже разрешают локальные зависимости:

```bash
melos bootstrap
```

Основные проверки и codegen:

```bash
melos run test
melos run analyze
melos run generate
dart run alteri_one_core doctor
```

Сборка native CLI из `applications/cli`:

```bash
dart build cli
```

Интерактивная установка self-contained executable:

```bash
dart install
```

`dart compile exe bin/main.dart` не является release-командой для workspace с native assets/build hooks: при их наличии компиляция падает или не включает требуемые assets. Использовать `dart build cli`/`dart install`; fallback на `dart compile exe` допустим только для явно проверенного package без build hooks.

Создание нового Tier 1 module scaffold выполняется CLI, а не ручным dynamic import:

```bash
dart run alteri_one_cli init module <name>
```

## 17. Конституция (принципы)

1. **Ядро владеет движком; capability-пакеты владеют миром.** Ядро не знает skills, календарей и почты, но владеет loop, deadlines, budgets, policy и protocol.
2. **Один конверт — на границе модуль↔ядро; на каждой внешней границе — адаптер.** Provider, MCP, telemetry и UX имеют собственные контракты, но не обходят внутренний envelope.
3. **Total time-boxing.** Любой run и вызов имеют finite deadline, путь отмены и budget; timeout без cancel и cost ceiling не считается time-boxing.
4. **Fail soft, recover loud.** Деградация разрешена только явной политикой и наблюдаема; неудачная изоляция, policy enforcement или sandbox приводят к отказу, а не к ослаблению режима.
5. **Least privilege by default.** Модуль получает конкретные capabilities, а не окружающую власть; расширение прав требует детерминированного allow и подтверждения человека.
6. **Versioned and interoperable.** Protocol, config, manifests и tools имеют версии и negotiation; несовместимость отвергается явно, без молчаливой подмены semantics.
7. **Determinism where it matters.** Clock, ids, provider и внешние adapters инъецируются; воспроизводимое поведение можно repair, commit и test.
8. **Cost is a resource, not a footnote.** Каждый run имеет token/USD budget и может исчерпать его; «бесплатного» обхода лимита не существует.
9. **Untrusted by default.** Tool, MCP и web output имеют provenance, информируют, но не авторизуют и не становятся инструкциями; Tier 2 исполняется fail closed.
10. **Configuration is data, therefore versioned.** YAML имеет `apiVersion`, schema, migrations и diagnostics; ошибка всегда указывает файл, позицию и invalid field.

## 18. Современный Dart (3.13)

### 18.1 Языковые возможности и границы применения

| Фича | Стабильна с | Назначение в AlteriOne |
|---|---:|---|
| Patterns, records, switch expressions | ≥ 3.0 | Sealed protocol/memory unions, exhaustive dispatch, immutable DTO |
| Null-aware elements collection (`?expr`) | ≥ 3.8 | Сборка optional fields без sentinel values |
| Dot shorthands | ≥ 3.10 | Короткие enum/constructor branches при сохранении compile-time type |
| Primary constructors + concise `new`/`factory` | 3.13 | Компактные immutable value objects и generated-style records |
| `async*`, extensions, `Isolate.run`, FFI | ≥ 3.0 | Streams/extensions/concurrency используются; FFI не используется продуктом |

Версия в таблице относится к стабилизации языковой фичи, а не к минимальной версии каждого package. В CI language version фиксируется 3.13, поэтому experimental preview и более новые feature не применяются.

Применяемые конструкции:

```dart
final values = <String>[first, ?nullable];

Color parseColor(String value) => switch (value) {
  'blue' => .blue,
  _ => throw FormatException('Unknown color: $value'),
};

class TraceSpan(final String traceId, final int sequence);
```

Используются sound null safety, records, patterns, exhaustive switch, extensions, `async*` и `Isolate.run` там, где абстракция `Concurrency` действительно соответствует платформе. `dart:mirrors` и runtime reflection не используются. `dart:ffi` не входит в product feature set: local models/FFI удалены из v1, а FFI/dynamic native loading рассматриваются только как усиление attack surface Tier 2.

### 18.2 Пакеты

| Назначение | Пакет и проверенная версия |
|---|---|
| Monorepo/versioning | `melos: ^8.9.0` |
| Codegen runner | `build_runner: ^2.16.1` |
| Sealed/data classes | `freezed: ^4.0.2`, `freezed_annotation` |
| JSON serialization | `json_serializable: ^6.14.1`, `json_annotation` |
| Long-term storage | `hive_ce: ^2.20.0`, `hive_ce_generator` |
| OpenAI-compatible transport | `package:http` и собственные DTO |
| CLI parsing | `args: ^2.7.0` |
| YAML | `yaml` |
| Localization | `intl` |
| MCP baseline | `mcp_dart: 2.4.2`; альтернатива `dart_mcp: 0.5.2`, experimental |
| Tests | `test` + `matcher` |
| Lint/format | `lints` + `dart_style` |
| Collections/utilities | `collection` + `async` |

Вне v1 фиксируются только кандидаты: для OTel — `opentelemetry` 0.18.x с Beta traces либо `dartastic_opentelemetry`; для vector recall — `sqlite3`/`sqlite-vec` или `local_hnsw` после отдельного eval. До ADR они не являются dependencies, не входят в lockfile и не влияют на API v1.

`hive` несовместим с Dart 3; `hive_adapters`, `open-telemetry` и `otlp_client` не существуют в актуальном виде. `openai_dart` и `cli_pkg` не выбраны: transport реализуется на `package:http`, CLI distribution — на `dart build cli`/`dart install`.

Codegen выполняется `freezed` 4.x и `json_serializable`. Freezed 3.x под Dart 3.13 генерировал нелегальный `final`-parameter, поэтому major-version guard обязателен в CI и lockfile.

### 18.3 Обязательные настройки package

В каждом package pubspec, включая публикуемые packages, закрепляется диапазон:

```yaml
environment:
  sdk: '>=3.13.0 <4.0.0'
```

Общий `analysis_options.yaml` содержит строгую типизацию границ:

```yaml
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-raw-types: true
```

`strict-casts` и `strict-raw-types` запрещают неявное проникновение `dynamic` через JSON-RPC, tool arguments, YAML и storage adapters. На границах parsing используются generated DTO и runtime schema validation; `Map<String, dynamic>` не служит внутренней моделью протокола. Codegen, `dart format --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos` и `dart test` обязательны перед acceptance.

## 19. Невозможности, риски и границы

| Риск | Вероятность | Влияние | Смягчение |
|---|---|---|---|
| Tier 2 на macOS/Windows начиная с v1 не поддерживается | Факт | Высокое | На этих ОС доступны только Tier 0 data packs и Tier 1 trusted code. Tier 2 завершает запуск явным refusal до создания процесса; fallback на `dart:isolate` запрещён. |
| Dart не загружает сторонний код в runtime VM | Факт | Высокое | Marketplace публикует Tier 0 data packs и precompiled AOT-exe с manifest, digest и подписью. Trusted code подключается build-time через codegen registry; «установка произвольного кода» не является API. |
| Wasm-компоненты как будущий plugin ABI пока непрактичны | Высокая | Среднее | `dart compile wasm` не интегрируется как plugin runtime с Wasmtime/Wasmer; открытые SDK issues 53884 и 56366 остаются gate. Wasm не входит в Фазы 0–4, ABI не обещается до working runtime. |
| Prompt injection нельзя устранить полностью | Высокая | Критическое | Детерминированно разрывается lethal trifecta: private data, untrusted content и outbound capability не соединяются одним агентом без policy. Хост задаёт provenance, capabilities узкие и mediated, data/instruction channels разделены. Это снижение риска, не гарантия. |
| Adversarial module обходит OS sandbox или получает capability | Средняя | Критическое | Отдельный процесс, `includeParentEnvironment: false`, bwrap/nsjail, cgroup v2, seccomp, network off, opaque secret ids, process-group kill и fail-closed. При невозможности enforcement модуль не запускается. |
| Компрометация signing/root key | Средняя | Критическое | Offline roots, промежуточные release keys, rotation/revocation, key id, signed provenance manifest и negative tests. Подпись подтверждает origin/целостность, но не добродетели поведения. |
| Eval-набор деградирует без обратной связи пользователей | Высокая | Среднее | Feedback сохраняется с consent/redaction, ревьюится и версионируется; baseline fixtures не заменяются model-generated expected results. Real-model eval не блокирует deterministic CI и регулярно сверяется с пользовательскими corrections. |
| Зависимость от экосистемы пакетов | Высокая | Среднее/высокое | `opentelemetry` в Dart — community/pre-1.0, `hive_ce` — форк без официального endorsement. Обе зависимости скрыты за внутренними ports, имеют contract tests и заменяемые implementations; API не закрепляет их типы. |
| «Model-agnostic» ограничен capability matrix локальных серверов | Высокая | Высокое | До запуска выполняется probe tools/streaming/JSON mode/context window/usage. Несовместимый provider явно исключается из цепочки; не обещается одинаковое поведение всех OpenAI-compatible endpoints. |
| Capability drift между локальными OpenAI-compatible servers | Высокая | Среднее | Закрытый набор conformance fixtures, versioned capability probe, provider-specific adapter и понятный refusal вместо универсального несовместимого request shape. |
| Frame flood, slowloris или бинарный payload исчерпывают память core | Средняя | Высокое | `maxFrameBytes` 8 MiB, backpressure, cancellation, progress и protocol-level denial; Tier 2 дополнительно ограничен cgroup и отдельным supervisor. |
| Cancellation оставляет процессы или повреждает transcript | Средняя | Высокое | CancelToken каскадируется до subagent/process group, выполняется drain, затем flush; integration fixture с fork tree проверяет reap и digest до/после прерывания. |
| Сборка AOT ломает native assets/build hooks | Средняя | Среднее | Release использует `dart build cli`/`dart install`; `dart compile exe` не является универсальным fallback. Artifact smoke-test проверяет запуск и встроенные assets. |
| Публичные пакеты содержат path-only dependencies | Средняя | Высокое | Coordinated versioning, `melos version`, release manifest и `dart pub publish --dry-run` для каждого publishable package. |
| MCP SDK и codegen меняют API между обновлениями | Высокая | Среднее | Revisions fixtures, adapter boundary, pinned versions, contract tests и ADR; core не экспортирует opinionated типы выбранной MCP-библиотеки. |
| Transcript содержит персональные или секретные данные | Средняя | Высокое | Redaction до persistence/export, opt-in OTel, no telemetry by default, memory delete/export/forget и явный retention. Ограничения доступа к state path задаются `AlteriOnePaths` и deployment policy. |

Этот документ не является юридическим заключением и не заменяет security-аудит реализации или операционной среды. Канал сообщений об уязвимостях, severity triage, сроки раскрытия и embargo описаны в `SECURITY.md`; Tier 2 не считается допустимым до прохождения adversarial acceptance.

## 20. Приложения

### 20.1. Глоссарий

| Термин | Определение |
|---|---|
| AOT | ahead-of-time compilation: исполняемый машинный код создаётся до запуска; runtime JIT/загрузка классов не используется. |
| Tier 0 / Skill Pack | Данные и ресурсы без исполняемого кода и authority; входят в контекст как недоверенный контент. Первый tier marketplace. |
| Tier 1 / Trusted Module | Код, линкуемый в AOT-бинарь build-time и регистрируемый generated registry. Доверенный по process/review; isolate не является security boundary. |
| Tier 2 / Untrusted Module | Произвольный сторонний код, исполняемый только отдельным precompiled AOT-exe под OS sandbox; macOS/Windows v1 — fail-closed. |
| Capability | Типизированное право на конкретную операцию, а не доступ к окружению целиком. Проверяется policy/broker-ом до выполнения. |
| Provenance | Назначенная хостом метка происхождения и доверия записи или фрагмента: user-stated, model-inferred, tool-observed, untrusted/private/secret category. Provenance не авторизует действие. |
| `Deadline` | Абсолютный/относительный предел времени, распространяемый вниз; дочерний вызов получает `min(perCall, remaining)`. |
| `CancelToken` | Каскадный сигнал отмены, передаваемый provider calls, subagents, transports и process-group Tier 2. |
| `CostBudget` | Лимиты расхода прогона по токенам и USD; usage, а не приблизительное число символов, определяет исчерпание. |
| `maxSteps` | Жёсткий предел числа reasoning/tool iterations, предотвращающий бесконечный цикл. |
| Stagnation detector | Останавливает повторяющийся tool call с теми же semantic inputs в заданном окне. |
| Compaction | Детерминированное сжатие старого контекста с сохранением фактов и исходного trust provenance; не операция повышения доверия. |
| Tool-result budgeting | Обрезка или выгрузка большого tool output в artifact с bounded pointer до добавления в model context. |
| Transcript | JSONL-журнал goal, model turns, tool calls/outcomes, policy decisions, usage, cost, timing и traceId; основа replay и debugging. |
| Unit / contract / integration / eval | Разные уровни проверки: локальная логика; внешний контракт; совместная работа компонентов; качество поведения реальной модели. |
| Eval | Версионированный набор сценариев и ожиданий для оценки качества, отдельно от deterministic unit/contract tests. |
| Framing | Способ выделения protocol payload: `Content-Length` header, пустая строка и ровно указанное число байт. |
| Handshake | `core.initialize` с negotiation protocol/module versions, capabilities, limits и явной degrade/refuse policy. |
| Handshake rejection | Fail-closed результат несовместимой версии, не молчаливое продолжение. |
| Fail-closed | При невозможности enforce policy, sandbox, signature или dependency система отказывает, а не переходит в более слабый режим. |
| ToolOutcome | Типизированный результат инструмента, включая denied/declined/error; denial возвращается модели и не обязан завершать весь run. |

### 20.2. Ключевые проектные решения

| Проектное решение | Где описано |
|---|---|
| Melos 8.9, root `pubspec.yaml`, pub workspaces и `resolution: workspace` | §2, §14 (Фаза 0), §16 |
| `alteri_one_platform` как граница `dart:io`/browser API | §2, §5, §14 (Фазы 0 и 5) |
| Три тира исполнения вместо isolate sandbox | §3, §14 (Фаза 3), §19 |
| Отсутствие Dart runtime dynamic import | §3, §14, §19 |
| Framed protocol, 8 MiB, cancel, progress, error taxonomy и handshake | §4, §14 (Фазы 0 и 3) |
| Валидный YAML, `apiVersion`, migrations, field-path diagnostics и config precedence | §5, §14 (Фаза 0), §16 |
| Единая policy-подсистема вместо дублирующихся hooks | §5, §8, §14 (Фаза 1) |
| Streaming, usage, capability probe и provider chain | §6, §14 (Фаза 0) |
| `hive_ce`, шесть memory collections и lifecycle записей | §7, §14 (Фаза 1) |
| Векторный recall вне v1 | §7, §15, §15.1 |
| Token-triggered compaction и tool-result budgeting | §7, §8, §14 (Фаза 1) |
| Deadline/CancelToken/CostBudget/maxSteps/stagnation и policy outcome | §8, §14 (Фаза 0) |
| Subagent budget/depth/concurrency/cascade cancel | §9, §14 (Фаза 4) |
| `FakeProvider`, injected clock/id, transcript/replay и test tiers | §11, §14 (Фаза 0) |
| Threat model, provenance и prompt-injection boundaries | §3, §7, §13, §19 |
| MCP `2026-07-28` как отдельный диалект, client раньше server | §12, §14 (Фазы 2 и 4) |
| Новый порядок фаз и перенос Tier 2 из Фазы 0 | §14 |
| Шесть решений по спорным вопросам | §15 и §15.1 |
| CLI packaging через `dart build cli`/`dart install`, v1 только CLI, web в Фазе 5 | §5, §13, §14 (Фаза 5), §15, §16 |
| Governance, community tracing, coordinated release и невозможности | §13, §14 (Фаза 6), §19, §20 |

### 20.3. Источники фактов

**Dart 3.13, workspaces и native tooling**

- <https://dart.dev/blog/announcing-dart-3-13>
- <https://dart.dev/language/primary-constructors>
- <https://dart.dev/tools/pub/workspaces>
- <https://dart.dev/tools/dart-compile#exe>
- <https://dart.dev/tools/cli-distribution>
- <https://dart.dev/language/concurrency#limitations-of-isolates>
- <https://api.dart.dev/dart-io/Platform/environment.html>
- <https://api.dart.dev/dart-io/exit.html>
- <https://api.dart.dev/dart-ffi/DynamicLibrary/DynamicLibrary/open.html>
- <https://api.dart.dev/dart-developer/Service/getInfo.html>
- <https://github.com/dart-lang/sdk/issues/10530>
- <https://github.com/dart-lang/sdk/issues/53884>
- <https://github.com/dart-lang/sdk/issues/56366>

**Melos и Dart packages**

- <https://pub.dev/packages/melos>
- <https://melos.invertase.dev/getting-started>
- <https://pub.dev/packages/hive>
- <https://pub.dev/packages/hive_ce>
- <https://pub.dev/packages/hive_ce_generator>
- <https://pub.dev/packages/freezed>
- <https://pub.dev/packages/json_serializable>
- <https://pub.dev/packages/build_runner>
- <https://pub.dev/packages/opentelemetry>
- <https://pub.dev/packages/dartastic_opentelemetry>
- <https://pub.dev/packages/dart_mcp>
- <https://pub.dev/packages/mcp_dart>
- <https://pub.dev/packages/args>
- <https://pub.dev/packages/local_hnsw>
- <https://pub.dev/packages/sqlite3>

**Agent Skills и Dart package skills**

- <https://agentskills.io/>
- <https://dart.dev/tools/package-skills>

**Model Context Protocol**

- <https://modelcontextprotocol.io/specification/2026-07-28>
- <https://github.com/modelcontextprotocol/modelcontextprotocol/releases/tag/2026-07-28>
- <https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices>

**OS sandbox и ресурсные ограничения**

- <https://github.com/containers/bubblewrap>
- <https://github.com/google/nsjail>
- <https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html>
- <https://www.kernel.org/doc/html/latest/userspace-api/seccomp.html>

**Tracing**

- <https://www.w3.org/TR/trace-context/>

**Prompt injection и agent security**

- <https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/>
- <https://arxiv.org/abs/2503.18813>
- <https://arxiv.org/abs/2506.08837>
- <https://genai.owasp.org/llmrisk/llm01-prompt-injection/>
- <https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks>
