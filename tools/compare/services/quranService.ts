import { API_BASE_URL, REQUIRED_FIELDS } from '../constants';
import { VerseResponse } from '../types';

export const fetchVerseByKey = async (key: string): Promise<VerseResponse> => {
  const response = await fetch(`${API_BASE_URL}/${key}?fields=${REQUIRED_FIELDS}`);
  
  if (!response.ok) {
    throw new Error(`Failed to fetch verse: ${response.statusText}`);
  }
  
  return response.json();
};
