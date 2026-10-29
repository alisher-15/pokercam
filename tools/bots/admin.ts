// The admin panel as an admin uses it: sign in, set a client's paid-until date.

/** Signs in to /admin and returns the session cookie. */
export async function adminSession(backendUrl: string, email: string, password: string): Promise<string> {
  const response = await fetch(`${backendUrl}/admin/login`, {
    method: "POST",
    body: new URLSearchParams({ email, password }),
    redirect: "manual",
  });
  const cookie = response.headers.getSetCookie().find((c) => c.startsWith("admin_session="));
  if (response.status !== 303 || response.headers.get("location") !== "/admin/clients" || !cookie) {
    throw new Error(`admin sign-in failed: ${String(response.status)} ${response.headers.get("location") ?? ""}`);
  }
  return cookie.split(";")[0] as string;
}

/** «Задать дату» on the client's card: access ends at the end of that day. */
export async function setPaidUntil(backendUrl: string, session: string, clientId: string, day: Date): Promise<void> {
  const response = await fetch(`${backendUrl}/admin/clients/${clientId}/paid-until`, {
    method: "POST",
    headers: { Cookie: session },
    body: new URLSearchParams({ paid_until: day.toISOString().slice(0, 10) }),
    redirect: "manual",
  });
  const location = response.headers.get("location") ?? "";
  if (response.status !== 303 || location !== `/admin/clients/${clientId}`) {
    throw new Error(`setting the paid-until date failed: ${String(response.status)} ${location}`);
  }
}

/** A JWT's claims, read without checking the signature (the bots only need their own client's id). */
export function claimsOf(jwt: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(jwt.split(".")[1] ?? "", "base64url").toString()) as Record<string, unknown>;
}
