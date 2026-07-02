import type { NextConfig } from 'next';
import { createMDX } from 'fumadocs-mdx/next';

const config: NextConfig = {
  reactStrictMode: true,
  output: 'standalone',
  serverExternalPackages: ['fumadocs-mdx'],
};

const withMDX = createMDX();

export default withMDX(config);
