enum S { X = "x", Y = "y" }
console.log(S.X, S.Y, S["x"], (S as any)["x"]);
