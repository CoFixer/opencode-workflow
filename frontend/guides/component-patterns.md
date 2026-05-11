# Component Patterns Guide

Reusable React component patterns.

## Compound Components

```tsx
// components/ui/tabs.tsx
import { createContext, useContext, useState } from 'react';

const TabsContext = createContext(null);

export function Tabs({ children, defaultValue }) {
  const [activeTab, setActiveTab] = useState(defaultValue);
  return (
    <TabsContext.Provider value={{ activeTab, setActiveTab }}>
      <div>{children}</div>
    </TabsContext.Provider>
  );
}

export function TabsList({ children }) {
  return <div className="flex space-x-1">{children}</div>;
}

export function TabsTrigger({ value, children }) {
  const { activeTab, setActiveTab } = useContext(TabsContext);
  return (
    <button
      className={activeTab === value ? 'active' : ''}
      onClick={() => setActiveTab(value)}
    >
      {children}
    </button>
  );
}

export function TabsContent({ value, children }) {
  const { activeTab } = useContext(TabsContext);
  if (activeTab !== value) return null;
  return <div>{children}</div>;
}
```

## Render Props Pattern

```tsx
// components/data-fetcher.tsx
export function DataFetcher({ url, render }) {
  const { data, isLoading, error } = useQuery({
    queryKey: [url],
    queryFn: () => fetch(url).then((r) => r.json()),
  });

  return render({ data, isLoading, error });
}

// Usage
<DataFetcher
  url="/api/users"
  render={({ data, isLoading }) => (
    isLoading ? <Spinner /> : <UserList users={data} />
  )}
/>
```

## Polymorphic Components

```tsx
// components/ui/box.tsx
import { ElementType, ComponentPropsWithoutRef } from 'react';

type BoxProps<T extends ElementType = 'div'> = {
  as?: T;
} & ComponentPropsWithoutRef<T>;

export function Box<T extends ElementType = 'div'>({
  as,
  ...props
}: BoxProps<T>) {
  const Component = as || 'div';
  return <Component {...props} />;
}
```
