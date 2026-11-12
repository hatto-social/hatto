export const HATTO_TERMS = {
  hatto: "https://hatto.social/ns#",
  rev: "hatto:rev",
  guid: "hatto:guid",
  event: "hatto:event",
  deck: { "@id": "hatto:deck", "@type": "@id" },
  streakDays: "hatto:streakDays",
  reviewCount: "hatto:reviewCount",
  measurementSource: "hatto:measurementSource",
};

/** Inline context. No remote fetch, so a missing context document cannot fail the parse. */
export const INLINE_CONTEXTS = ["https://www.w3.org/ns/activitystreams", HATTO_TERMS];

export function contextDocument(): { "@context": typeof HATTO_TERMS } {
  return { "@context": HATTO_TERMS };
}
