# Frontend Development Guides

This directory contains guides for React frontend development.

## Available Guides

| Guide | Purpose |
|-------|---------|
| api-integration.md | Connecting to backend APIs |
| best-practices.md | General React best practices |
| component-patterns.md | Reusable component patterns |
| data-fetching.md | TanStack Query patterns |
| loading-and-error-states.md | UI state handling |
| performance.md | Optimization techniques |
| routing-guide.md | React Router patterns |
| styling-guide.md | TailwindCSS conventions |
| tanstack-query.md | Query caching and invalidation |
| typescript-standards.md | TypeScript conventions |

## Quick Reference

### Creating a New Page

```tsx
// app/pages/my-feature/MyFeaturePage.tsx
import { useQuery } from '@tanstack/react-query';
import { myFeatureService } from '@/services/my-feature.service';
import { LoadingSpinner } from '@/components/ui/loading-spinner';
import { ErrorAlert } from '@/components/ui/error-alert';

export function MyFeaturePage() {
  const { data, isLoading, isError } = useQuery({
    queryKey: ['my-feature'],
    queryFn: () => myFeatureService.getAll(),
  });

  if (isLoading) return <LoadingSpinner />;
  if (isError) return <ErrorAlert message="Failed to load data" />;
  if (!data?.length) return <EmptyState message="No items found" />;

  return (
    <div className="container mx-auto p-4">
      <h1 className="text-2xl font-bold">My Feature</h1>
      {/* ... */}
    </div>
  );
}
```

### Standard Component Structure

```
app/
├── pages/
│   └── my-feature/
│       └── MyFeaturePage.tsx
├── components/
│   ├── ui/              # shadcn components
│   └── my-feature/      # feature components
├── hooks/
│   └── useMyFeature.ts
├── services/
│   └── my-feature.service.ts
├── types/
│   └── my-feature.types.ts
└── routes/
    └── AppRoutes.tsx
```

## Related

- **Agents:** [frontend-developer](../../agents/development/frontend-developer.md)
- **Skills:** [run-fullstack](../../skills/dev/run-fullstack/SKILL.md)
