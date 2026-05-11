# API Integration Guide

Connecting React frontend to NestJS backend.

## Service Pattern

```typescript
// services/api.client.ts
import axios from 'axios';

export const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

apiClient.interceptors.request.use((config) => {
  const token = localStorage.getItem('token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});
```

## React Query Integration

```typescript
// services/my-feature.service.ts
import { apiClient } from './api.client';

export const myFeatureService = {
  getAll: () => apiClient.get('/api/my-feature').then((r) => r.data),
  getById: (id: string) => apiClient.get(`/api/my-feature/${id}`).then((r) => r.data),
  create: (data: CreateDto) => apiClient.post('/api/my-feature', data).then((r) => r.data),
  update: (id: string, data: UpdateDto) => apiClient.patch(`/api/my-feature/${id}`, data).then((r) => r.data),
  delete: (id: string) => apiClient.delete(`/api/my-feature/${id}`).then((r) => r.data),
};
```

## Hook Pattern

```typescript
// hooks/use-my-feature.ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { myFeatureService } from '@/services/my-feature.service';

export function useMyFeatures() {
  return useQuery({
    queryKey: ['my-features'],
    queryFn: () => myFeatureService.getAll(),
  });
}

export function useCreateMyFeature() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: myFeatureService.create,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['my-features'] });
    },
  });
}
```

## Error Handling

```typescript
import { useToast } from '@/hooks/use-toast';

export function useMyFeatures() {
  const { toast } = useToast();
  
  return useQuery({
    queryKey: ['my-features'],
    queryFn: () => myFeatureService.getAll(),
    onError: (error: AxiosError) => {
      toast({
        title: 'Error',
        description: error.response?.data?.message || 'Failed to load data',
        variant: 'destructive',
      });
    },
  });
}
```
