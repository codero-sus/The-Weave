PYTHON ?= python3

.PHONY: help test run todo dashboard build lint clean

help:
	@echo "make test        run the test suite"
	@echo "make run         serve the dashboard example on :8420"
	@echo "make todo        serve the Todo example on :8421"
	@echo "make build       build the dashboard into dist/"
	@echo "make lint        run pyflakes (if installed)"
	@echo "make clean       remove caches and build output"

test:
	$(PYTHON) -m unittest discover -s tests -v

run:
	./weave run examples/dashboard.weave --port 8420

todo:
	./weave run examples/todo.weave --port 8421

build:
	./weave build examples/dashboard.weave -o dist

lint:
	-$(PYTHON) -m pyflakes the_weave tests

clean:
	rm -rf dist .pytest_cache
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
