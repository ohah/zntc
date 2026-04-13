"use client";

// TanStack Router + Start: route 컴포넌트가 server function 호출
import { useState } from "react";
import { getUser } from "./server-fn";

export default function UserRoute() {
  const [id, setId] = useState(1);
  const handle = async () => {
    const u = await getUser(id);
    console.log(u);
  };
  return (
    <div>
      <button onClick={handle}>Load {id}</button>
      <button onClick={() => setId(id + 1)}>Next</button>
    </div>
  );
}
