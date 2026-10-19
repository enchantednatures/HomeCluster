import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://test.k6.io';

export const options = {
  vus: 2,
  duration: '10s',
};

export default function () {
  const responses = http.batch([
    ['GET', BASE_URL + '/'],
    ['GET', BASE_URL + '/contacts.php'],
  ]);

  responses.forEach((response) => {
    check(response, {
      'status is 200': (r) => r.status === 200,
    });
  });

  sleep(0.5);
}
