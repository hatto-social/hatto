export function pgConfig(connectionString: string): {
  host: string;
  user?: string;
  password?: string;
  database: string;
} {
  const url = new URL(connectionString);
  const host = url.searchParams.get('host') ?? url.hostname;
  const database = decodeURIComponent(url.pathname.replace(/^\//, ''));
  const user = url.username ? decodeURIComponent(url.username) : undefined;
  const password = url.password ? decodeURIComponent(url.password) : undefined;
  return { host, user, password, database };
}
