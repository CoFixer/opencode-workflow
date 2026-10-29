# Frontend Patterns (React + React Router 7)

Generic React conventions for any project using the `.opencode` workflow. Project-specific routes, design tokens, and API services belong in `.project/docs/`.

> **Before coding**: read the project's `PROJECT_KNOWLEDGE`, `PROJECT_API_INTEGRATION`, and design guidelines. If a project convention conflicts with this guide, the project wins.

## Structure

Prefer feature-based folders once the app grows:

```
src/
├── app/                  # Router setup, providers
├── features/{feature}/   # pages, components, hooks, api
├── components/           # shared UI primitives
├── hooks/                # shared hooks
├── lib/                  # utilities (cn, dates, formatters)
├── services/             # API clients
├── types/                # shared types
└── styles/               # global CSS / tokens
```

Rules:
- Co-locate feature code; avoid a single global `components/` dump.
- Lazy-load route modules where the router supports it.
- One API client with interceptors beats ad-hoc `fetch` calls.

## Routes (React Router 7)

Use the data-router API (`createBrowserRouter` / `RouterProvider`), not Remix loaders.

```tsx
// app/router.tsx
import { createBrowserRouter, RouterProvider } from 'react-router';

const router = createBrowserRouter([
  {
    path: '/resources',
    lazy: () => import('../features/resources/routes/list'),
  },
  {
    path: '/resources/:id',
    lazy: () => import('../features/resources/routes/detail'),
  },
]);

export function AppRouter() {
  return <RouterProvider router={router} />;
}
```

Rules:
- Route-level code splitting via `lazy`.
- Route guards check auth **and** role; render a 403 route, do not silently redirect loops.
- Keep route paths in one place so links and tests share them.

## Data fetching

Use the project's server-state library (TanStack Query is common):

```tsx
export function useResources() {
  return useQuery({
    queryKey: ['resources'],
    queryFn: () => api.get('/resources'),
    staleTime: 30_000,
  });
}
```

Rules:
- Query keys include every filter/pagination input.
- Mutations invalidate the affected keys.
- Do not copy server state into global state.
- Show loading, empty, and error states for every async view.

## Components

```tsx
interface ResourceCardProps {
  resource: Resource;
}

export function ResourceCard({ resource }: ResourceCardProps) {
  return (
    <article className="rounded-xl border p-4">
      <h3 className="text-lg font-semibold">{resource.name}</h3>
      <Link to={`/resources/${resource.id}`}>View details</Link>
    </article>
  );
}
```

Rules:
- Function components + explicit prop types.
- No business logic in presentational components.
- Use the project's design tokens/classes; avoid hardcoded hex values.
- Prefer composition over boolean-prop explosion.

## Forms

Use React Hook Form + Zod when the project already does:

```tsx
const schema = z.object({
  name: z.string().min(1),
  quantity: z.coerce.number().int().min(0),
});

type FormValues = z.infer<typeof schema>;

export function ResourceForm({ onSubmit }: { onSubmit: (v: FormValues) => void }) {
  const form = useForm<FormValues>({ resolver: zodResolver(schema) });
  return (
    <form onSubmit={form.handleSubmit(onSubmit)}>
      <input {...form.register('name')} />
      {form.formState.errors.name && <span>{form.formState.errors.name.message}</span>}
      <button type="submit">Save</button>
    </form>
  );
}
```

- Validate on the client for UX and on the server for truth.
- Disable submit while pending; surface server field errors.

## Errors

- Route-level error boundaries for render/data errors.
- Toast or inline alerts for mutation errors.
- Never render raw exception messages in production UI.

## Styling

- Tailwind: utility-first, mobile-first, use `cn()` for conditionals.
- Centralize tokens (colors, spacing, radius) in one config; do not duplicate hex values.
- Dark theme: verify contrast, not just appearance.
- Visual regression tests are recommended for shared components.

## Accessibility

- Semantic elements (`button`, `nav`, `main`) before ARIA.
- Every icon-only control needs an accessible name.
- Visible focus states; keyboard path for every flow.
- Respect `prefers-reduced-motion`.
- Dynamic content (chat, toasts) should use live regions.

## Commands

Read `package.json`; typical scripts:

```bash
npm run dev
npm run build
npm run typecheck
npm run lint
npm run test:e2e
```

## Where project specifics live

| Need | Location |
|------|----------|
| Routes, screens, integration state | `.project/docs/PROJECT_API_INTEGRATION.MD` |
| Design tokens/components | `.project/docs/PROJECT_DESIGN_GUIDELINES.MD` |
| API contract | `.project/docs/PROJECT_API.MD` |
| Current gaps | `.project/status/` |

Do **not** hardcode project names, routes, or tokens in `.opencode`.
