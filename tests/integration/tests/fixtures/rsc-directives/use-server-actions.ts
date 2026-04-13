"use server";

export async function createUser(name: string) {
  return { id: 1, name };
}

export async function deleteUser(id: number) {
  return { ok: true, id };
}
