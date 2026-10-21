# Schemantic spike (durable copy)

Recorded 2026-10-21. Environment spike for T2 (`docs/spec/open-questions.md` Q1).
Original run lived in `/tmp/opencode/schemantic_spike`; this file keeps the
source schema and a generated-output excerpt so the evidence survives outside the
temporary directory. The temporary copy is also referenced from
`docs/spikes/m0-environment.md`.

## Environment

- Dart SDK 3.13.5
- `schemantic` 1.0.0
- `schemantic_builder` 1.0.0
- `build_runner` 2.16.x

## Source schema

`lib/schemantic_spike.dart`:

```dart
import 'package:schemantic/schemantic.dart';

part 'schemantic_spike.g.dart';

@Schema()
abstract class $SpikeUser {
  @Field(description: 'Display name of the user')
  String get name;

  @Field(name: 'years_old', description: 'Age of the user')
  int? get age;

  @AnyOf([int, String])
  Object get zipCode;
}
```

## Generated output (excerpt)

`lib/schemantic_spike.g.dart` (abridged):

```dart
base class SpikeUser {
  factory SpikeUser.fromJson(Map<String, dynamic> json) => $schema.parse(json);

  SpikeUser({
    required String name,
    int? age,
    required SpikeUserZipCode zipCode,
  }) {
    _json = {'name': name, 'years_old': ?age, 'zipCode': zipCode.value};
  }

  static const SchemanticType<SpikeUser> $schema = _SpikeUserTypeFactory();

  String get name => _json['name'] as String;
  int? get age => (_json['years_old'] as num?)?.toInt();

  // Possible return values are `int`, `String`
  Object? get zipCode => _json['zipCode'] as Object?;

  Map<String, dynamic> toJson() => _json;
}

final class SpikeUserZipCode {
  SpikeUserZipCode.int(int this.value);
  SpikeUserZipCode.string(String this.value);
  final Object? value;
}

base class _SpikeUserTypeFactory extends SchemanticType<SpikeUser> {
  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'SpikeUser',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'name': <String, Object?>{
          'type': 'string',
          'description': 'Display name of the user',
        },
        'years_old': <String, Object?>{
          'type': 'integer',
          'description': 'Age of the user',
        },
        'zipCode': <String, Object?>{
          'anyOf': [
            <String, Object?>{'type': 'integer'},
            <String, Object?>{'type': 'string'},
          ],
        },
      },
      'required': ['name', 'zipCode'],
    },
    dependencies: [],
  );
}
```

## Outcome

Annotations (`@Schema`, `@Field`, `@AnyOf`) generate a working `SchemanticType`
and JSON schema on Dart 3.13.5. `[VERIFY]` remains for edge cases (nested types,
enums, defaults) per `open-questions.md` Q1.
