import '../../core/shortcuts/default_shortcuts.dart';

/// Stateful shell branches in the same order as [appRouterProvider].
enum AppBranch {
  generation,
  localGallery,
  onlineGallery,
  settings,
  promptConfig,
  statistics,
  tagLibrary,
  vibeLibrary,
  preciseRefLibrary,
}

/// All internal destinations exposed by the desktop rail and mobile menu.
const List<AppBranch> allNavigationBranches = [
  AppBranch.generation,
  AppBranch.localGallery,
  AppBranch.onlineGallery,
  AppBranch.vibeLibrary,
  AppBranch.preciseRefLibrary,
  AppBranch.promptConfig,
  AppBranch.tagLibrary,
  AppBranch.statistics,
  AppBranch.settings,
];

/// Global navigation shortcuts and their destination branches.
const Map<String, AppBranch> globalNavigationShortcutBranches = {
  ShortcutIds.navigateToGeneration: AppBranch.generation,
  ShortcutIds.navigateToLocalGallery: AppBranch.localGallery,
  ShortcutIds.navigateToOnlineGallery: AppBranch.onlineGallery,
  ShortcutIds.navigateToSettings: AppBranch.settings,
  ShortcutIds.navigateToRandomConfig: AppBranch.promptConfig,
  ShortcutIds.navigateToStatistics: AppBranch.statistics,
  ShortcutIds.navigateToTagLibrary: AppBranch.tagLibrary,
  ShortcutIds.navigateToVibeLibrary: AppBranch.vibeLibrary,
};

/// Branches pinned directly to the mobile bottom navigation.
const List<AppBranch> mobileNavigationBranches = [
  AppBranch.generation,
  AppBranch.localGallery,
  AppBranch.onlineGallery,
  AppBranch.tagLibrary,
  AppBranch.settings,
];

int mobileNavigationIndexForBranch(int branchIndex) {
  final branch = AppBranch.values[branchIndex];
  final mobileIndex = mobileNavigationBranches.indexOf(branch);
  return mobileIndex == -1 ? mobileNavigationBranches.length : mobileIndex;
}
