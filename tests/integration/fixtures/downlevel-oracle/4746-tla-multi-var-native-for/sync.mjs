export function record(events, label, value) {
  events.push('init:' + label);
  return value;
}
