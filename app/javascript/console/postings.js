// **How full each post is**, counted from the postings the projection already carries. `sent`
// counts against capacity, because that is what the engine refuses on; `working` is who has
// arrived, and the gap between them is the gang still walking in.
export function postings(crew) {
  const sent = new Map()
  const working = new Map()
  for (const member of Object.values(crew || {})) {
    if (member.posting) sent.set(member.posting, (sent.get(member.posting) || 0) + 1)
    if (member.station) working.set(member.station, (working.get(member.station) || 0) + 1)
  }
  return { sent, working }
}
