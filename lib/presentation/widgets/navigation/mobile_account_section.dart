import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/localization_extension.dart';
import '../../../data/models/auth/saved_account.dart';
import '../../providers/account_manager_provider.dart';
import '../../providers/auth_mode_provider.dart';
import '../../providers/auth_provider.dart';
import '../auth/account_avatar.dart';
import '../auth/login_form_container.dart';
import '../common/app_toast.dart';

/// Account switcher and session actions shown in portrait navigation.
class MobileAccountSection extends ConsumerWidget {
  const MobileAccountSection({
    super.key,
    required this.hostContext,
    required this.sheetContext,
  });

  final BuildContext hostContext;
  final BuildContext sheetContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    final accounts = ref.watch(accountManagerNotifierProvider).accounts;
    final currentAccount = _currentAccount(accounts, authState.accountId);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (currentAccount != null)
          ListTile(
            key: const ValueKey('mobile-current-account'),
            leading: AccountAvatarSmall(account: currentAccount, size: 40),
            title: Text(currentAccount.displayName),
            subtitle: Text(context.l10n.auth_currentAccount),
            trailing: Icon(Icons.check, color: theme.colorScheme.primary),
          ),
        for (final account in accounts)
          if (account.id != currentAccount?.id)
            ListTile(
              key: ValueKey('mobile-account-${account.id}'),
              leading: AccountAvatarSmall(account: account, size: 36),
              title: Text(account.displayName),
              trailing: const Icon(Icons.swap_horiz),
              onTap: () => _switchAccount(ref, account),
            ),
        ListTile(
          key: const ValueKey('mobile-add-account'),
          leading: const Icon(Icons.add),
          title: Text(context.l10n.auth_addAccount),
          onTap: () => _openAddAccountDialog(ref),
        ),
        ListTile(
          key: const ValueKey('mobile-logout'),
          leading: Icon(Icons.logout, color: theme.colorScheme.error),
          title: Text(
            context.l10n.auth_logout,
            style: TextStyle(color: theme.colorScheme.error),
          ),
          onTap: () {
            final authNotifier = ref.read(authNotifierProvider.notifier);
            Navigator.of(sheetContext).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              authNotifier.logout();
            });
          },
        ),
      ],
    );
  }

  SavedAccount? _currentAccount(
    List<SavedAccount> accounts,
    String? accountId,
  ) {
    if (accounts.isEmpty) return null;
    for (final account in accounts) {
      if (account.id == accountId) return account;
    }
    return accounts.first;
  }

  Future<void> _switchAccount(WidgetRef ref, SavedAccount account) async {
    final accountManager = ref.read(accountManagerNotifierProvider.notifier);
    final authNotifier = ref.read(authNotifierProvider.notifier);
    Navigator.of(sheetContext).pop();
    final token = await accountManager.getAccountToken(account.id);

    if (token == null) {
      if (hostContext.mounted) {
        AppToast.info(hostContext, hostContext.l10n.auth_tokenNotFound);
      }
      return;
    }

    final success = await authNotifier.switchAccount(
      account.id,
      token,
      displayName: account.displayName,
      accountType: account.accountType,
    );
    if (!success && hostContext.mounted) {
      final errorCode = ref.read(authNotifierProvider).errorCode;
      AppToast.error(hostContext, _switchErrorMessage(hostContext, errorCode));
    }
  }

  String _switchErrorMessage(BuildContext context, AuthErrorCode? errorCode) {
    return switch (errorCode) {
      AuthErrorCode.networkTimeout => context.l10n.auth_error_networkTimeout,
      AuthErrorCode.networkError => context.l10n.auth_error_networkError,
      AuthErrorCode.authFailed ||
      AuthErrorCode.tokenInvalid => context.l10n.auth_error_authFailed,
      AuthErrorCode.credentialsLoginUnavailable =>
        context.l10n.auth_error_credentialsLoginUnavailable,
      AuthErrorCode.serverError => context.l10n.auth_error_serverError,
      _ => context.l10n.auth_loginFailed,
    };
  }

  void _openAddAccountDialog(WidgetRef ref) {
    final authModeNotifier = ref.read(authModeNotifierProvider.notifier);
    final authNotifier = ref.read(authNotifierProvider.notifier);
    Navigator.of(sheetContext).pop();
    authModeNotifier.reset();
    authNotifier.clearError(delayMs: 0);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hostContext.mounted) _showAddAccountDialog(hostContext);
    });
  }

  void _showAddAccountDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Text(
                      context.l10n.auth_addAccount,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
                LoginFormContainer(
                  onLoginSuccess: () => Navigator.pop(dialogContext),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
