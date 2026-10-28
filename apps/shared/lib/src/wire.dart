import 'dart:convert';

/// Copy of [json] without null values, at every level.
///
/// The generated `toJson()` writes absent optional fields as null, but the
/// schemas never allow null: an absent field is left out of the message.
Map<String, dynamic> withoutNulls(Map<String, dynamic> json) => {
  for (final MapEntry(:key, :value) in json.entries)
    if (value != null) key: _clean(value),
};

Object? _clean(Object? value) => switch (value) {
  Map<String, dynamic> map => withoutNulls(map),
  List<dynamic> list => [
    for (final item in list)
      if (item != null) _clean(item),
  ],
  _ => value,
};

/// Encodes a message or REST body (the result of a generated `toJson()`) for sending.
String encodeWire(Map<String, dynamic> json) => jsonEncode(withoutNulls(json));
