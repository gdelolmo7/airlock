import Foundation

/// Whether the screen guide is in this build AND switched on — the one
/// question code outside the guide asks about it.
///
/// The guide is private: the public copy of this code is exported without
/// it, and there `AIRLOCK_GUIDE` is undefined and the answer is always no
/// (see the top of Package.swift). In the owner's build it is
/// `GuidePreferences.isOn`, which also needs the `ALGuide` key packaging
/// writes, so even a build with the code carries no guide unless asked.
enum GuideSwitch {
    static var isOn: Bool {
        #if AIRLOCK_GUIDE
        GuidePreferences.isOn
        #else
        false
        #endif
    }
}
