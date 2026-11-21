import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../contracts/contracts.dart';

/// The seller's contacts as label/value lines, in a fixed order; empty fields are left out.
List<(String, String)> sellerContactLines(
  AppLocalizations l10n,
  SellerContacts contacts,
) => [
  if (contacts.phone != null) (l10n.sellerPhone, contacts.phone!),
  if (contacts.whatsapp != null) (l10n.sellerWhatsapp, contacts.whatsapp!),
  if (contacts.telegram != null)
    (
      l10n.sellerTelegram,
      contacts.telegram!.startsWith('@')
          ? contacts.telegram!
          : '@${contacts.telegram}',
    ),
  if (contacts.email != null) (l10n.sellerEmail, contacts.email!),
  if (contacts.website != null) (l10n.sellerWebsite, contacts.website!),
];

/// SPEC 8.4: whom the club calls when its license is in grace or blocked. Text can be selected and copied.
class SellerContactsView extends StatelessWidget {
  const SellerContactsView({super.key, required this.contacts, this.color});

  final SellerContacts contacts;

  /// Text color; the theme's by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final style = TextStyle(color: color);
    final note = contacts.note;
    return Column(
      key: const Key('seller-contacts'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.sellerContactsTitle,
          style: style.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        for (final (label, value) in sellerContactLines(l10n, contacts))
          SelectableText('$label: $value', style: style),
        if (note != null) SelectableText(note, style: style),
      ],
    );
  }
}
