// Forces the "academic" theme unconditionally, since Documenter's own THEMES
// list (JuliaDocs/Documenter.jl, src/html/HTMLWriter.jl) is a hardcoded
// internal constant with no public make.jl-level extension point -- this is
// the only way to activate a custom theme.css that isn't in that list.
//
// Runs after themeswap.js (Documenter loads this asset after the built-in
// theme <link>s and themeswap.js, in that order), so it reliably overrides
// whatever class themeswap.js just set from localStorage/OS preference.
document.getElementsByTagName("html")[0].className = "theme--academic";
