export function values(events, label, entries) {
  return {
    [Symbol.iterator]() {
      let index = 0;
      return {
        next() {
          return index < entries.length ? { value: entries[index++], done: false } : { done: true };
        },
        return() {
          events.push('close:' + label);
          return { done: true };
        },
      };
    },
  };
}
