import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

// Routes that never require authentication
const PUBLIC_ROUTES = new Set(["/login"]);

// API routes that are always public (auth endpoints + health check)
const PUBLIC_API_PREFIXES = ["/api/auth/", "/api/health"];

function isAuthenticated(request: NextRequest): boolean {
  // Check cookie-based auth
  const authCookie = request.cookies.get("mc_auth");
  if (authCookie && authCookie.value === process.env.AUTH_SECRET) {
    return true;
  }

  // Check API key header (for internal scripts/agents)
  const apiKey = request.headers.get("X-API-Key");
  if (apiKey && apiKey === process.env.AUTH_SECRET) {
    return true;
  }

  return false;
}

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Always allow public pages (login)
  if (PUBLIC_ROUTES.has(pathname)) {
    return NextResponse.next();
  }

  // Always allow public API routes (auth + health)
  if (PUBLIC_API_PREFIXES.some((prefix) => pathname.startsWith(prefix))) {
    return NextResponse.next();
  }

  // Check authentication
  if (!isAuthenticated(request)) {
    // For API routes: return 401 JSON (not a redirect)
    if (pathname.startsWith("/api/")) {
      return NextResponse.json(
        { error: "Unauthorized", message: "Authentication required" },
        { status: 401 }
      );
    }

    // For page routes: redirect to login
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("from", pathname);
    return NextResponse.redirect(loginUrl);
  }

  return NextResponse.next();
}

export const config = {
  matcher: [
    /*
     * Match all request paths except:
     * - _next/static (static files)
     * - _next/image (image optimization files)
     * - favicon.ico (favicon file)
     * - public files (with extension)
     */
    "/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)"],
};
