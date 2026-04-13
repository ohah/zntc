"use server";

// TanStack Start: server function (직접 client에서 호출 가능)
export async function getUser(id: number) {
  return { id, name: `user-${id}` };
}

export async function listPosts() {
  return [{ id: 1, title: "hello" }];
}
