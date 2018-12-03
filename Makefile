.DEFAULT_GOAL := all
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

NODE_VERSION := 10.14.1
NODE_DIR := node-v$(NODE_VERSION)-linux-x64
AWS_LAMBDA_LAYER_NAME := nadesiko
AWS_LAMBDA_FUNCTION_NAME := nadesiko-sample
AWS_LAMBDA_HANDLER := function.ハンドラ
AWS_LAMBDA_ROLE := arn:aws:iam::669411927913:role/lambda_basic_execution

define make_subdir
    @mkdir -p $(@D)
endef

# http://postd.cc/auto-documented-makefile/
.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

$(NODE_DIR):
	curl -#sL https://nodejs.org/dist/v$(NODE_VERSION)/node-v$(NODE_VERSION)-linux-x64.tar.xz | xz -dc - | tar xvf -
	@touch $@

package-lock.json: package.json
	npm install
	@touch $@

build/runtime.zip: $(NODE_DIR) node_modules package.json package-lock.json bootstrap runtime.js
	$(make_subdir)
	zip -r $@ $^

build/layer.json: build/runtime.zip
	$(make_subdir)
	@echo 'Publish lambda layer "$(AWS_LAMBDA_LAYER_NAME)"...'
	@aws lambda publish-layer-version \
		--layer-name $(AWS_LAMBDA_LAYER_NAME) \
		--zip-file fileb://build/runtime.zip > $@
	@cat $@ | jq .

.PHONY: layer
layer: build/layer.json ## レイヤーを更新

layer_arn = $(shell cat build/layer.json | jq -r '.LayerVersionArn')
layer_version = $(shell cat build/layer.json | jq -r '.Version')

build/function.zip: function.nako
	$(make_subdir)
	zip $@ $^

build/function.json: build/layer.json build/function.zip
	$(make_subdir)
	@if aws lambda get-function --function-name $(AWS_LAMBDA_FUNCTION_NAME) > /dev/null 2>&1 ; then \
		echo 'Update lambda function "$(AWS_LAMBDA_FUNCTION_NAME)"...' && \
		aws lambda update-function-configuration \
			--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
			--runtime provided \
			--handler $(AWS_LAMBDA_HANDLER) \
			--role $(AWS_LAMBDA_ROLE) \
			--layers $(layer_arn) > /dev/null && \
		aws lambda update-function-code \
			--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
			--zip-file fileb://build/function.zip > $@ ; \
	else \
		echo 'Create lambda function "$(AWS_LAMBDA_FUNCTION_NAME)"...' && \
		aws lambda create-function \
			--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
			--runtime provided \
			--handler $(AWS_LAMBDA_HANDLER) \
			--role $(AWS_LAMBDA_ROLE) \
			--layers $(layer_arn)  \
			--zip-file fileb://build/function.zip > $@ ; \
	fi
	@cat $@ | jq .

.PHONY: function
function: build/function.json ## 関数を更新

.PHONY: test
test: build/function.json ## テスト
	@echo 'Invoke lambda function "$(AWS_LAMBDA_FUNCTION_NAME)"...'
	@aws lambda invoke \
		--function-name $(AWS_LAMBDA_FUNCTION_NAME) \
		--payload '{"text":"Hello"}' \
		build/response.txt > build/response.json
	@cat build/response.json | jq .
	@cat build/response.txt
	@echo

build/publish.json: build/layer.json
	@echo 'Publish lambda layer "$(AWS_LAMBDA_LAYER_NAME)"...'
	@aws lambda add-layer-version-permission \
		--layer-name $(AWS_LAMBDA_LAYER_NAME) \
		--version-number $(layer_version) \
		--principal "*" \
		--statement-id publish \
		--action lambda:GetLayerVersion > $@
	@cat $@ | jq .

.PHONY: publish ## レイヤーを公開
publish: build/publish.json

.PHONY: all
all: test

.PHONY: clean
clean: ## ビルドしたものを削除
	rm -Rf $(NODE_DIR) build
