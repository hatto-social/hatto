/** Same statements the stress workers send through `pg`. Prisma remains the app path. */
export const RESOLVE_POINTER_SQL = `
SELECT d.current_version, d.current_path, d.content_hash, d.byte_size
FROM decks d
JOIN deck_acl a ON a.deck_id = d.id
WHERE d.id = $1 AND a.user_id = $2
`;
