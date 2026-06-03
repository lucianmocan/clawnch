import { createMDX } from 'fumadocs-mdx/next';

const config = {
  reactStrictMode: true,
  serverExternalPackages: ['fumadocs-mdx'],
};

const withMDX = createMDX();

export default withMDX(config);
