import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from evaluate import build_request, ranked, run_batched, run_case, seed_scores, validate_response


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        self.case = {
            'case_id': 'comedy_test',
            'collection_name': 'Dumb funny', 'members': [{'id': 8699, 'title': 'Anchorman'}],
            'candidates': [{'id': 9472, 'title': 'Dodgeball'}, {'id': 24428, 'title': 'The Avengers'}],
            'keywords': [{'id': 179430, 'name': 'aftercreditsstinger', 'seed_count': 2}],
            'baseline': {'9472': 1.0, '24428': 0},
        }
        self.payload = build_request(self.case)

    def response(self):
        answers = {}
        for key, question in self.payload['questions'].items():
            if question['type'] == 'noul':
                answers[key] = {'type': 'noul', 'noul': 0.01}
            else:
                count = len(question['criteria'])
                level = count - 1 if key.endswith('9472') else 0
                answers[key] = {'type': 'score', 'score': level, 'confidence': 1,
                                'probabilities': {str(i): int(i == level) for i in range(count)}}
        return {'model': 'jev-1.13.0', 'usage': {'input_tokens': 100}, 'answers': answers}

    def test_questions_point_to_candidates_and_keep_name_verbatim(self):
        self.assertEqual(self.payload['state']['collection_name'], 'Dumb funny')
        self.assertIn('`candidates[0]`', self.payload['questions']['fit_9472']['instructions'])
        self.assertIn('`candidates[1]`', self.payload['questions']['fit_24428']['instructions'])
        self.assertEqual(len(self.payload['questions']), 5)
        # Technical metadata is evaluated by Jev, not silently removed by the experiment.
        self.assertIn('keyword_179430', self.payload['questions'])

    def test_baseline_deduplicates_per_seed_and_excludes_members(self):
        feeds = [[{'id': 1}, {'id': 1}, {'id': 2}], [{'id': 2}]]
        scores = seed_scores(feeds, {2})
        self.assertEqual(scores, {1: 1.0})

    def test_valid_response_ranks_comedy_first(self):
        response = self.response()
        validate_response(self.payload, response)
        self.assertEqual(ranked(self.case, {'response': response})[0]['id'], 9472)

    def test_missing_answer_is_not_silently_ranked(self):
        response = self.response()
        del response['answers']['fit_9472']
        with self.assertRaises(ValueError):
            validate_response(self.payload, response)

    def test_out_of_range_and_nonfinite_scores_rejected(self):
        for bad in (-1, 4, float('nan'), True):
            response = self.response()
            response['answers']['fit_9472']['score'] = bad
            with self.assertRaises(ValueError):
                validate_response(self.payload, response)

    def test_invalid_distributions_rejected(self):
        response = self.response()
        response['answers']['fit_9472']['probabilities']['0'] = 0.5
        with self.assertRaises(ValueError):
            validate_response(self.payload, response)

    def test_ties_are_stable_when_candidate_order_changes(self):
        case = copy.deepcopy(self.case)
        case['baseline'] = {}
        first = [movie['id'] for movie in ranked(case)]
        case['candidates'].reverse()
        self.assertEqual(first, [movie['id'] for movie in ranked(case)])

    def test_identical_request_replays_cache_without_an_api_key(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch('evaluate.OUTPUT', Path(directory)), \
                patch('evaluate.request_json', return_value=self.response()) as request:
            first = run_case(self.case, 'test-key')
            second = run_case(self.case, None, cache_only=True)
            self.assertFalse(first['cached'])
            self.assertTrue(second['cached'])
            self.assertEqual(request.call_count, 1)
            self.assertNotIn('test-key', ''.join(p.read_text() for p in Path(directory).rglob('*.json')))
            changed = dict(self.case, collection_name='Different intent')
            with self.assertRaises(RuntimeError):
                run_case(changed, None, cache_only=True)

    def test_small_batches_merge_answers_and_separate_keywords(self):
        complete = self.response()

        def fake_call(case, key, **options):
            names = build_request(case)['questions']
            response = dict(complete, answers={name: complete['answers'][name] for name in names})
            return {'response': response, 'seconds': 0.1, 'cached': False}

        with tempfile.TemporaryDirectory() as directory, \
                patch('evaluate.OUTPUT', Path(directory)), \
                patch('evaluate.run_case', side_effect=fake_call) as request:
            result = run_batched(self.case, 'test-key', 1)
            self.assertEqual(result['request_count'], 3)
            self.assertEqual(result['response']['usage']['input_tokens'], 300)
            self.assertEqual(result['response']['answers'], complete['answers'])
            for call in request.call_args_list:
                batch = call.args[0]
                self.assertFalse(batch['candidates'] and batch['keywords'])
                self.assertLessEqual(len(batch['candidates']), 1)
            cached = run_batched(self.case, None, 1, cache_only=True)
            self.assertTrue(cached['cached'])
            self.assertEqual(request.call_count, 3)


if __name__ == '__main__':
    unittest.main()
