//! Private default getter domain: one emitted runtime helper artifact instance.
//! Keys are compiler-owned provider output paths relative to that helper.
//! No classification of public export objects or host filename API is involved.
pub const source =
    \\var __pmDefault = (function () {
    \\  var readers = Object.create(null);
    \\  return function (value, getter, key, lookup) {
    \\    if (arguments.length === 3) {
    \\      readers[key] = getter;
    \\      return value;
    \\    }
    \\    return readers[key] || function () { return value; };
    \\  };
    \\})();
;
