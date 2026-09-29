import type { NextConfig } from "next";
import path from "node:path";

const nextConfig: NextConfig = {
  // Pin Turbopack root to this package (avoids parent lockfile confusion).
  turbopack: {
    root: path.join(__dirname),
  },
};

export default nextConfig;
