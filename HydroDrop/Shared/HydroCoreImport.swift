// Makes HydroCore's types, such as `DayKey`, visible to every file in the target that
// compiles this one, the way they were when `DayKey.swift` sat in HydroDrop/Models and was
// compiled straight into the app, the widgets and the Watch app. Without it, each of the
// two dozen files that use a day key would need its own `import HydroCore`.
//
// It sits in HydroDrop/Shared because the app and the widget extension both compile that
// folder; the Watch app lists this file by name in project.yml.
@_exported import HydroCore
