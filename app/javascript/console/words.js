// An id as a player reads it: `blown_head` → "blown head".
export function words(value) {
  return String(value).replace(/_/g, " ")
}
