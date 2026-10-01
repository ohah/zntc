const _Self = 23;

enum Ref {
  First = 1,
  Next = Ref.First + 2,
}

enum Self {
  Self = 1,
  Next = Self.Self + 2,
}

console.log(JSON.stringify([Ref.Next, Self.Self, Self.Next, _Self]));
