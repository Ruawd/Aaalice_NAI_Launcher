import 'package:flutter/material.dart';

import '../../../core/utils/localization_extension.dart';

enum LocalImageContextAction {
  sendToTextToImage,
  sendToImg2Img,
  sendToReversePrompt,
  sendToStyleTransfer,
  sendToPreciseReference,
  saveToPreciseRefLibrary,
  sendToKrita,
  upscale,
  importMetadata,
  copyPrompt,
  copySeed,
  showInFolder,
  delete,
}

class LocalImageContextMenu {
  const LocalImageContextMenu._();

  static Future<LocalImageContextAction?> show(
    BuildContext context, {
    required Offset position,
    required bool hasImportableMetadata,
    required bool hasPrompt,
    required bool hasSeed,
    required bool isKritaConnected,
  }) {
    if (MediaQuery.sizeOf(context).width < 600) {
      return _showMobileActions(
        context,
        hasImportableMetadata: hasImportableMetadata,
        hasPrompt: hasPrompt,
        hasSeed: hasSeed,
      );
    }

    return showMenu<LocalImageContextAction>(
      context: context,
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: buildEntries(
        context,
        hasImportableMetadata: hasImportableMetadata,
        hasPrompt: hasPrompt,
        hasSeed: hasSeed,
        isKritaConnected: isKritaConnected,
      ),
    );
  }

  static Future<LocalImageContextAction?> _showMobileActions(
    BuildContext context, {
    required bool hasImportableMetadata,
    required bool hasPrompt,
    required bool hasSeed,
  }) {
    return Navigator.of(context).push<LocalImageContextAction>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (pageContext) {
          Widget action(
            LocalImageContextAction value,
            IconData icon,
            String label, {
            bool destructive = false,
          }) {
            final color = destructive
                ? Theme.of(pageContext).colorScheme.error
                : null;
            return ListTile(
              key: ValueKey('mobile-gallery-action-${value.name}'),
              leading: Icon(icon, color: color),
              title: Text(
                label,
                style: color == null ? null : TextStyle(color: color),
              ),
              onTap: () => Navigator.of(pageContext).pop(value),
            );
          }

          return Scaffold(
            appBar: AppBar(
              title: Text(pageContext.l10n.localGallery_title),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(pageContext).pop(),
              ),
            ),
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                children: [
                  action(
                    LocalImageContextAction.delete,
                    Icons.delete_outline,
                    pageContext.l10n.common_delete,
                    destructive: true,
                  ),
                  const Divider(),
                  action(
                    LocalImageContextAction.sendToTextToImage,
                    Icons.text_fields,
                    pageContext.l10n.onlineGallery_sendToTextToImage,
                  ),
                  action(
                    LocalImageContextAction.sendToImg2Img,
                    Icons.image_outlined,
                    pageContext.l10n.localGallery_sendToImg2Img,
                  ),
                  action(
                    LocalImageContextAction.sendToReversePrompt,
                    Icons.manage_search_rounded,
                    pageContext.l10n.localGallery_sendToReversePrompt,
                  ),
                  action(
                    LocalImageContextAction.sendToStyleTransfer,
                    Icons.palette_outlined,
                    pageContext.l10n.localGallery_sendToStyleTransfer,
                  ),
                  action(
                    LocalImageContextAction.sendToPreciseReference,
                    Icons.center_focus_strong,
                    pageContext.l10n.localGallery_sendToPreciseReference,
                  ),
                  action(
                    LocalImageContextAction.saveToPreciseRefLibrary,
                    Icons.bookmark_add_outlined,
                    pageContext.l10n.localGallery_saveToPreciseRefLibrary,
                  ),
                  action(
                    LocalImageContextAction.upscale,
                    Icons.zoom_in,
                    pageContext.l10n.gallery_upscale,
                  ),
                  if (hasImportableMetadata || hasPrompt || hasSeed)
                    const Divider(),
                  if (hasImportableMetadata)
                    action(
                      LocalImageContextAction.importMetadata,
                      Icons.data_object,
                      pageContext.l10n.localGallery_importImageMetadata,
                    ),
                  if (hasPrompt)
                    action(
                      LocalImageContextAction.copyPrompt,
                      Icons.content_copy,
                      pageContext.l10n.localGallery_copyPrompt,
                    ),
                  if (hasSeed)
                    action(
                      LocalImageContextAction.copySeed,
                      Icons.tag,
                      pageContext.l10n.localGallery_copySeed,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Future<LocalImageContextAction?> showSendActions(
    BuildContext context, {
    required Offset position,
    required bool isKritaConnected,
  }) {
    return showMenu<LocalImageContextAction>(
      context: context,
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: buildSendEntries(context, isKritaConnected: isKritaConnected),
    );
  }

  static List<PopupMenuEntry<LocalImageContextAction>> buildEntries(
    BuildContext context, {
    required bool hasImportableMetadata,
    required bool hasPrompt,
    required bool hasSeed,
    required bool isKritaConnected,
  }) {
    final hasImageInfoActions = hasImportableMetadata || hasPrompt || hasSeed;

    return [
      ...buildSendEntries(context, isKritaConnected: isKritaConnected),
      if (hasImageInfoActions) const PopupMenuDivider(),
      if (hasImportableMetadata)
        _item(
          context,
          value: LocalImageContextAction.importMetadata,
          icon: Icons.data_object,
          label: context.l10n.localGallery_importImageMetadata,
        ),
      if (hasPrompt)
        _item(
          context,
          value: LocalImageContextAction.copyPrompt,
          icon: Icons.content_copy,
          label: context.l10n.localGallery_copyPrompt,
        ),
      if (hasSeed)
        _item(
          context,
          value: LocalImageContextAction.copySeed,
          icon: Icons.tag,
          label: context.l10n.localGallery_copySeed,
        ),
      const PopupMenuDivider(),
      _item(
        context,
        value: LocalImageContextAction.showInFolder,
        icon: Icons.folder_open,
        label: context.l10n.localGallery_showInFolder,
      ),
      _item(
        context,
        value: LocalImageContextAction.delete,
        icon: Icons.delete_outline,
        label: context.l10n.common_delete,
        destructive: true,
      ),
    ];
  }

  static List<PopupMenuEntry<LocalImageContextAction>> buildSendEntries(
    BuildContext context, {
    required bool isKritaConnected,
  }) {
    return [
      _item(
        context,
        value: LocalImageContextAction.sendToTextToImage,
        icon: Icons.text_fields,
        label: context.l10n.onlineGallery_sendToTextToImage,
      ),
      _item(
        context,
        value: LocalImageContextAction.sendToImg2Img,
        icon: Icons.image_outlined,
        label: context.l10n.localGallery_sendToImg2Img,
      ),
      _item(
        context,
        value: LocalImageContextAction.sendToReversePrompt,
        icon: Icons.manage_search_rounded,
        label: context.l10n.localGallery_sendToReversePrompt,
      ),
      _item(
        context,
        value: LocalImageContextAction.sendToStyleTransfer,
        icon: Icons.palette_outlined,
        label: context.l10n.localGallery_sendToStyleTransfer,
      ),
      _item(
        context,
        value: LocalImageContextAction.sendToPreciseReference,
        icon: Icons.center_focus_strong,
        label: context.l10n.localGallery_sendToPreciseReference,
      ),
      _item(
        context,
        value: LocalImageContextAction.saveToPreciseRefLibrary,
        icon: Icons.bookmark_add_outlined,
        label: context.l10n.localGallery_saveToPreciseRefLibrary,
      ),
      _item(
        context,
        value: LocalImageContextAction.sendToKrita,
        icon: Icons.brush_outlined,
        label: context.l10n.localGallery_sendToKrita,
        enabled: isKritaConnected,
      ),
      _item(
        context,
        value: LocalImageContextAction.upscale,
        icon: Icons.zoom_in,
        label: context.l10n.gallery_upscale,
      ),
    ];
  }

  static PopupMenuItem<LocalImageContextAction> _item(
    BuildContext context, {
    required LocalImageContextAction value,
    required IconData icon,
    required String label,
    bool enabled = true,
    bool destructive = false,
  }) {
    final color = !enabled
        ? Theme.of(context).disabledColor
        : destructive
        ? Theme.of(context).colorScheme.error
        : null;

    return PopupMenuItem<LocalImageContextAction>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: color == null ? null : TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
