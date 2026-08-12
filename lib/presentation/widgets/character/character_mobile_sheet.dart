import 'package:flutter/material.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_constants.dart';
import '../../../data/models/character/character_prompt.dart';
import '../../providers/character_position_canvas_provider.dart';
import '../../providers/character_prompt_provider.dart';
import '../../providers/image_generation_provider.dart';
import '../../providers/tag_library_page_provider.dart';
import '../tag_library/tag_library_picker_dialog.dart';
import 'character_position_canvas.dart';
import 'inline_character_card.dart';
import 'inline_character_editor.dart';

/// 手机端多角色完整管理面板。
///
/// 桌面布局会把角色卡常驻在提示词下方；移动布局没有这块区域，因此角色
/// 工具栏按钮必须承载添加、编辑、启停、删除和位置设置的完整入口。
class CharacterMobileSheet extends ConsumerWidget {
  const CharacterMobileSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const FractionallySizedBox(
        heightFactor: 0.9,
        child: CharacterMobileSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(characterPromptNotifierProvider);
    final characters = config.characters;
    final params = ref.watch(generationParamsNotifierProvider);
    final isV4Model = ImageModels.isV4Model(params.model);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
          child: Row(
            children: [
              Icon(Icons.people, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.prompt_characterPrompts,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (characters.isNotEmpty)
                IconButton(
                  key: const Key('character-mobile-clear-all'),
                  onPressed: () => confirmClearAllCharacters(context, ref),
                  tooltip: l10n.characterEditor_clearAll,
                  icon: Icon(
                    Icons.delete_sweep_outlined,
                    color: theme.colorScheme.error,
                  ),
                ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                tooltip: l10n.common_close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        if (!isV4Model)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _InfoBanner(
              icon: Icons.info_outline,
              text: l10n.characterMobile_v4Only,
              color: theme.colorScheme.tertiary,
            ),
          ),
        if (characters.isNotEmpty && isV4Model)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                CharacterPositionModeSegments(
                  onCanvasTap: () {
                    ref
                        .read(characterPromptNotifierProvider.notifier)
                        .setGlobalAiChoice(false);
                    ref.read(characterPositionCanvasProvider.notifier).open();
                    Navigator.of(context).pop();
                  },
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    config.globalAiChoice
                        ? l10n.characterCanvas_aiHint
                        : l10n.characterMobile_customPositionHint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: characters.isEmpty
              ? _EmptyCharacters(onAdd: () => _showAddMenu(context, ref))
              : ListView.separated(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    16,
                    14,
                    16,
                    16 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  itemCount: characters.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    if (index == characters.length) {
                      return OutlinedButton.icon(
                        key: const Key('character-mobile-add'),
                        onPressed: () => _showAddMenu(context, ref),
                        icon: const Icon(Icons.add),
                        label: Text(l10n.character_addCharacter),
                      );
                    }

                    final character = characters[index];
                    return InlineCharacterCard(
                      key: ValueKey('mobile-${character.id}'),
                      character: character,
                      index: index,
                      total: characters.length,
                      inlineEditor: true,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _showAddMenu(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<_MobileCharacterAddAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(l10n.character_addCharacter),
                subtitle: Text(l10n.characterMobile_addSubtitle),
              ),
              _AddTile(
                icon: Icons.female,
                color: const Color(0xFFEC4899),
                label: l10n.characterEditor_genderFemale,
                value: _MobileCharacterAddAction.female,
              ),
              _AddTile(
                icon: Icons.male,
                color: const Color(0xFF3B82F6),
                label: l10n.characterEditor_genderMale,
                value: _MobileCharacterAddAction.male,
              ),
              _AddTile(
                icon: Icons.transgender,
                color: const Color(0xFF8B5CF6),
                label: l10n.characterEditor_genderOther,
                value: _MobileCharacterAddAction.other,
              ),
              _AddTile(
                icon: Icons.library_books_outlined,
                color: Theme.of(context).colorScheme.tertiary,
                label: l10n.characterMobile_addFromLibrary,
                value: _MobileCharacterAddAction.library,
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    final notifier = ref.read(characterPromptNotifierProvider.notifier);
    final gender = action.gender;
    if (gender != null) {
      notifier.addCharacter(gender);
      _selectLast(ref);
      return;
    }

    final entry = await showDialog(
      context: context,
      builder: (context) => const TagLibraryPickerDialog(),
    );
    if (entry == null) return;
    ref.read(tagLibraryPageNotifierProvider.notifier).recordUsage(entry.id);
    notifier.addCharacter(
      CharacterGender.female,
      name: entry.displayName,
      prompt: entry.content,
      thumbnailPath: entry.thumbnail,
    );
    _selectLast(ref);
  }

  void _selectLast(WidgetRef ref) {
    final characters = ref.read(characterPromptNotifierProvider).characters;
    if (characters.isNotEmpty) {
      ref.read(selectedCharacterIdProvider.notifier).select(characters.last.id);
    }
  }
}

enum _MobileCharacterAddAction {
  female(CharacterGender.female),
  male(CharacterGender.male),
  other(CharacterGender.other),
  library(null);

  const _MobileCharacterAddAction(this.gender);

  final CharacterGender? gender;
}

class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color color;
  final String label;
  final _MobileCharacterAddAction value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).pop(value),
    );
  }
}

class _EmptyCharacters extends StatelessWidget {
  const _EmptyCharacters({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline,
              size: 54,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.characterMobile_emptyTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              l10n.characterMobile_emptySubtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('character-mobile-empty-add'),
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: Text(l10n.character_addCharacter),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
