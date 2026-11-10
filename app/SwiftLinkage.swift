// The app targets have no other Swift sources, but they link libiSHApp/libiSHLinux,
// which contain Swift (TerminalSurface, SwiftTerm). Having one Swift file here makes
// Xcode link the app with the Swift driver so the Swift runtime support libraries
// are included.
