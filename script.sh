#!/bin/bash

TRIGGER=$1
REPO=$2
BRANCH_NAME=$3
PR_NUMBER=$4
COMMIT_SHA=$5
CLIENT_ENV=$6
SA_ID=$ORG_ACF_BACKEND_SA
KV_ID=$ORG_ACF_BACKEND_KV
APP_NAME=$(echo $APP_NAME | tr -s ' ' '_')
PLUGIN_NAME=$(echo $PLUGIN_NAME | tr a-z A-Z)

cd /workspace

KV_SUBSCRIPTION_ID=`echo "$KV_ID" | awk -F '/' '{print $3}'`
KV_NAME=`echo "$KV_ID" | awk -F '/' '{print $9}'`
KV_RGNAME=`echo "$KV_ID" | awk -F '/' '{print $5}'`
SA_NAME=`echo "$SA_ID" | awk -F '/' '{print $9}'`
SA_SUBSCRIPTION_ID=`echo "$SA_ID" | awk -F '/' '{print $3}'`
CUSTOMER_NAME=`echo "$REPO" | awk -F '/' '{print $2}'`

if [[ "$MANAGED_LZ" != "true" ]]; then
  az login --identity
  az account set --subscription $KV_SUBSCRIPTION_ID
  PAT=`az keyvault secret show --name $CUSTOMER_NAME --vault $KV_NAME --query value -o tsv`
  export GH_TOKEN=$PAT
else
  bearerToken=$ACTIONS_ID_TOKEN_REQUEST_TOKEN
  runtimeUrl=$ACTIONS_ID_TOKEN_REQUEST_URL
  runtimeUrl="${runtimeUrl}&audience=api://AzureADTokenExchange"
  JWTTOKEN=$(curl -H "Authorization: bearer $bearerToken" $runtimeUrl | jq -r ".value")
  ip=$(curl -s http://ipinfo.io/json | jq -r '.ip')
  az login --service-principal -u $ORG_ACF_BACKEND_CLIENT_ID --tenant $ORG_ACF_BACKEND_TENANT_ID --federated-token $JWTTOKEN -o none >/dev/null 2>&1
  az account set --subscription $KV_SUBSCRIPTION_ID >/dev/null 2>&1
  az keyvault network-rule add --name $KV_NAME --resource-group $KV_RGNAME --ip-address $ip >/dev/null 2>&1
  az keyvault network-rule wait --name $KV_NAME --updated >/dev/null 2>&1
  az keyvault network-rule add --name $KV_NAME --resource-group $KV_RGNAME --ip-address '0.0.0.0' >/dev/null 2>&1
  while true; do
    PAT=`az keyvault secret show --name $CUSTOMER_NAME --vault $KV_NAME --query value -o tsv`
    if [ -n "$PAT" ]; then
      echo "Key vault secret fetched sucesfully"
      export GH_TOKEN=$PAT
      az keyvault network-rule remove --name $KV_NAME --resource-group $KV_RGNAME --ip-address $ip >/dev/null 2>&1
      az keyvault network-rule wait --name $KV_NAME --updated >/dev/null 2>&1
      az keyvault network-rule remove --name $KV_NAME --resource-group $KV_RGNAME --ip-address '0.0.0.0' >/dev/null 2>&1
      az logout >/dev/null 2>&1
      break
    else
      echo "Waiting for Key Vault access..."
      sleep 1
    fi
  done
  az login --identity
  az account set --subscription $SA_SUBSCRIPTION_ID
fi

git config --global user.email "acf@nordcloud.com"
git config --global user.name "lzt-azure-architects-sa"

git clone "https://outh2:$PAT@github.com/$REPO.git"

cd $CUSTOMER_NAME
git checkout $BRANCH_NAME

chmod 755 scripts/decompress.sh
./scripts/decompress.sh $CLIENT_ENV

pwsh -command "Connect-AzAccount -Identity"

commentResponse(){
  gh api \
      --silent \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      repos/$REPO/issues/$PR_NUMBER/comments \
      -F body="Azure Container Instance has received your request, it is being prepared and should be ready soon. Please wait a few moments while the request is being handled."
  }

commentResult(){
                  echo "<details><summary>$1</summary>" > msg.txt
                  echo "    " >> msg.txt
                  cat $2 | sed 's/^/    /' >> msg.txt
                  echo "</details>" >> msg.txt
                  COMMENT_BODY=`cat msg.txt`
                  gh api \
                    --silent \
                    --method POST \
                    -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    repos/$REPO/issues/$PR_NUMBER/comments \
                    -F body="$COMMENT_BODY"
               }
terragruntPlan(){
  commentResponse
  CURRENT_DIR=`pwd`
  if [[ "$1" != "RUNALL" ]]; then
  terragrunt plan -parallelism=50 -no-color -input=false -compact-warnings -out=$CURRENT_DIR/plan-$COMMIT_SHA.out 2>&1 | tee plan-$COMMIT_SHA.txt || true
  terragrunt show -json plan-$COMMIT_SHA.out | jq -r '([.resource_changes[]?.change.actions?]|flatten)|{"create":(map(select(.=="create"))|length),"update":(map(select(.=="update"))|length),"delete":(map(select(.=="delete"))|length)}' > summary.txt
  else
  terragrunt run-all plan --terragrunt-exclude-dir PROVISIONER --terragrunt-exclude-dir PROVISIONER/CICD --terragrunt-exclude-dir APPLZ/SAMPLE-SUB_NAME_OR_SUB_ID_APP3 -parallelism=50 -no-color -input=false -compact-warnings -out=$CURRENT_DIR/plan-$COMMIT_SHA.out 2>&1 | tee plan-$COMMIT_SHA.txt || true
  grep "Plan:" plan-$COMMIT_SHA.txt > summary.txt
  fi

  azcopy login --identity
  azcopy copy plan-$COMMIT_SHA.out https://$SA_NAME.blob.core.windows.net/tfplan/plan-$1-$CLIENT_ENV-$COMMIT_SHA.out
  SIZE=`ls -lh plan-$COMMIT_SHA.txt | awk '{print $5}' | sed 's/[^0-9]*//g'`
  SIZE_LETTER=`ls -lh plan-$COMMIT_SHA.txt | awk '{print $5}' | sed 's/[^A-z]*//g'`

  if grep -q "exit status 1" "plan-$COMMIT_SHA.txt"; then
    if ([ "$SIZE_LETTER" = "K" ] && [ $SIZE -ge 100 ]) || [ "$SIZE_LETTER" = "M" ]; then
      split -b 100000 -a 4 plan-$COMMIT_SHA.txt
      for i in xaa*; do
      commentResult "$1 PLAN Failed - Part $(echo $i | cut -c4-5)" ./$(echo $i)
      done
    else
      commentResult "$1 PLAN Failed" plan-$COMMIT_SHA.txt
      exit 1
    fi
  else
    if ([ "$SIZE_LETTER" = "K" ] && [ $SIZE -ge 100 ]) || [ "$SIZE_LETTER" = "M" ]; then
      split -b 100000 -a 4 plan-$COMMIT_SHA.txt
      for i in xaa*; do
      commentResult "$1 PLAN - Part $(echo $i | cut -c4-5)" ./$(echo $i)
      done
    else
      commentResult "$1 PLAN" plan-$COMMIT_SHA.txt
    fi
    commentResult "$1 PLAN Summary" summary.txt
  fi
}

terragruntApply(){
  commentResponse
  azcopy login --identity
  azcopy copy https://$SA_NAME.blob.core.windows.net/tfplan/plan-$1-$CLIENT_ENV-$COMMIT_SHA.out plan-$COMMIT_SHA.out
  if [[ "$1" != "RUNALL" ]]; then
    terragrunt apply -parallelism=50 -no-color -input=false -compact-warnings plan-$COMMIT_SHA.out 2>&1 | tee apply_output_$COMMIT_SHA.txt
    if (grep -q "Apply complete!" "apply_output_$COMMIT_SHA.txt" && ! grep -q "PSP STATUS: failed" "apply_output_$COMMIT_SHA.txt"); then
      SUCCESS="true"
    else
      SUCCESS="false"
    fi
  else
    terragrunt run-all apply --terragrunt-non-interactive --terragrunt-exclude-dir PROVISIONER --terragrunt-exclude-dir PROVISIONER/CICD --terragrunt-exclude-dir APPLZ/SAMPLE-SUB_NAME_OR_SUB_ID_APP3 -parallelism=50 -no-color -input=false -compact-warnings 2>&1 | tee apply_output_$COMMIT_SHA.txt
    MODULE_COUNT=$(grep "\- Module " "apply_output_$COMMIT_SHA.txt" | wc -l)
    APPLY_COUNT=$(grep "Apply complete!" "apply_output_$COMMIT_SHA.txt" | wc -l)
    echo "Module count: $MODULE_COUNT"
    echo "Apply count: $APPLY_COUNT"
    if [ $MODULE_COUNT -eq $APPLY_COUNT ]; then
      SUCCESS="true"
    else
      SUCCESS="false"
    fi
  fi
  SIZE=`ls -lh apply_output_$COMMIT_SHA.txt | awk '{print $5}' | sed 's/[^0-9]*//g'`
  SIZE_LETTER=`ls -lh apply_output_$COMMIT_SHA.txt | awk '{print $5}' | sed 's/[^A-z]*//g'`

  if [[ $SUCCESS == "true" ]] ; then
    if ([ "$SIZE_LETTER" = "K" ] && [ $SIZE -ge 100 ]) || [ "$SIZE_LETTER" = "M" ]; then
      split -b 100000 -a 4 apply_output_$COMMIT_SHA.txt
      for i in xaa*; do
      commentResult "$1 APPLY Success - Part $(echo $i | cut -c4-5)" ./$(echo $i)
      done
    else
      commentResult "$1 APPLY Success" apply_output_$COMMIT_SHA.txt
    fi
    azcopy remove https://$SA_NAME.blob.core.windows.net/tfplan/plan-$1-$CLIENT_ENV-$COMMIT_SHA.out
    echo "Terragrunt apply success"
  else
    if ([ "$SIZE_LETTER" = "K" ] && [ $SIZE -ge 100 ]) || [ "$SIZE_LETTER" = "M" ]; then
      split -b 100000 -a 4 apply_output_$COMMIT_SHA.txt
      for i in xaa*; do
      commentResult "$1 APPLY Failed - Part $(echo $i | cut -c4-5)" ./$(echo $i)
      done
    else
      commentResult "$1 APPLY Failed" apply_output_$COMMIT_SHA.txt ;
    fi
    echo "Terragrunt apply failed"
    exit 1 ;
  fi
}

createCommit(){
  cd /workspace/$CUSTOMER_NAME/terragrunt/$CLIENT_ENV
  if [[ $1 == "PROVISIONER" ]]; then
    git add provisioner_details.hcl
    git commit -m "feat: provisioner apply result files" ;
    git push -u origin $BRANCH_NAME
  elif [[ $1 == "CICD" ]]; then
    git add cicd_details.hcl
    git commit -m "feat: cicd apply result files" ;
    git push -u origin $BRANCH_NAME
  elif ([ $1 == "APPLZ" ] && [ -d "/workspace/$CUSTOMER_NAME/terragrunt/$CLIENT_ENV/APPLZ/$APP_NAME/applz-details" ]); then
    cd APPLZ/$APP_NAME/applz-details
    git add */*.tf
    git add */*.json
    git commit -m "feat: Application Landing zone variable files commit"
    git push -u origin $BRANCH_NAME
  fi
}


if [[ $TRIGGER == "terragrunt-provisioner-plan" ]]
then
  export ARM_USE_OIDC=true
  export ARM_USE_MSI=true
  export ARM_CLIENT_ID=$ORG_ACF_BACKEND_CLIENT_ID
  export ORG_BACKEND_MSI_CLIENT_ID=$ORG_ACF_BACKEND_MSI_CLIENT_ID  #change the key name as required for terragrunt
  cd terragrunt/$CLIENT_ENV/PROVISIONER
  terragruntPlan "PROVISIONER"
elif [[ $TRIGGER == "terragrunt-provisioner-apply" ]]
then
  export ARM_USE_OIDC=true
  export ARM_USE_MSI=true
  export ARM_CLIENT_ID=$ORG_ACF_BACKEND_CLIENT_ID
  export ORG_BACKEND_MSI_CLIENT_ID=$ORG_ACF_BACKEND_MSI_CLIENT_ID  #change the key name as required for terragrunt
  cd terragrunt/$CLIENT_ENV/PROVISIONER
  terragruntApply "PROVISIONER"
  createCommit "PROVISIONER"
elif [[ $TRIGGER == "terragrunt-cicd-plan" ]]
then
  export ARM_USE_OIDC=true
  export ARM_USE_MSI=true
  export ARM_CLIENT_ID=$ORG_ACF_BACKEND_CLIENT_ID
  export ORG_BACKEND_MSI_CLIENT_ID=$ORG_ACF_BACKEND_MSI_CLIENT_ID  #change the key name as required for terragrunt
  cd terragrunt/$CLIENT_ENV/PROVISIONER/CICD
  terragruntPlan "CICD"
elif [[ $TRIGGER == "terragrunt-cicd-apply" ]]
then
  export ARM_USE_OIDC=true
  export ARM_USE_MSI=true
  export ARM_CLIENT_ID=$ORG_ACF_BACKEND_CLIENT_ID
  export ORG_BACKEND_MSI_CLIENT_ID=$ORG_ACF_BACKEND_MSI_CLIENT_ID  #change the key name as required for terragrunt
  cd terragrunt/$CLIENT_ENV/PROVISIONER/CICD
  terragruntApply "CICD"
  createCommit "CICD"
elif [[ $TRIGGER == "terragrunt-core-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE
  terragruntPlan "CORE"
elif [[ $TRIGGER == "terragrunt-core-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE
  terragruntApply "CORE"
elif [[ $TRIGGER == "terragrunt-audit-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/AUDIT
  terragruntPlan "AUDIT"
elif [[ $TRIGGER == "terragrunt-audit-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/AUDIT
  terragruntApply "AUDIT"
elif [[ $TRIGGER == "terragrunt-governance-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/GOVERNANCE
  terragruntPlan "GOVERNANCE"
elif [[ $TRIGGER == "terragrunt-governance-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/GOVERNANCE
  terragruntApply "GOVERNANCE"
elif [[ $TRIGGER == "terragrunt-management-ext-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/MANAGEMENT
  terragruntPlan "MANAGEMENT"
elif [[ $TRIGGER == "terragrunt-management-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/MANAGEMENT
  terragruntApply "MANAGEMENT"
elif [[ $TRIGGER == "terragrunt-network-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/NETWORK
  terragruntPlan "NETWORK"
elif [[ $TRIGGER == "terragrunt-network-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/NETWORK
  terragruntApply "NETWORK"
elif [[ $TRIGGER == "terragrunt-sharedservices-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/SHAREDSERVICES
  terragruntPlan "SHAREDSERVICES"
elif [[ $TRIGGER == "terragrunt-sharedservices-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/SHAREDSERVICES
  terragruntApply "SHAREDSERVICES"
elif [[ $TRIGGER == "terragrunt-identity-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/IDENTITY
  terragruntPlan "IDENTITY"
elif [[ $TRIGGER == "terragrunt-identity-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/IDENTITY
  terragruntApply "IDENTITY"
elif [[ $TRIGGER == "terragrunt-applicationgateway-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/APPLICATIONGATEWAY
  terragruntPlan "APPLICATIONGATEWAY"
elif [[ $TRIGGER == "terragrunt-applicationgateway-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/APPLICATIONGATEWAY
  terragruntApply "APPLICATIONGATEWAY"
elif [[ $TRIGGER == "terragrunt-firewall-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/FIREWALL
  terragruntPlan "FIREWALL"
elif [[ $TRIGGER == "terragrunt-firewall-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/FIREWALL
  terragruntApply "FIREWALL"
elif [[ $TRIGGER == "terragrunt-applz-plan" ]]
then
  export ARM_USE_MSI=true
  cd "terragrunt/$CLIENT_ENV/APPLZ/$APP_NAME"
  terragruntPlan "APPLZ"
elif [[ $TRIGGER == "terragrunt-applz-apply" ]]
then
  export ARM_USE_MSI=true
  cd "terragrunt/$CLIENT_ENV/APPLZ/$APP_NAME"
  terragruntApply "APPLZ"
  createCommit "APPLZ"
elif [[ $TRIGGER == "terragrunt-azurepolicies-plan" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/AZUREPOLICIES
  terragruntPlan "AZUREPOLICIES"
elif [[ $TRIGGER == "terragrunt-azurepolicies-apply" ]]
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/AZUREPOLICIES
  terragruntApply "AZUREPOLICIES"
elif [[ $TRIGGER == "terragrunt-runall-plan" ]]
# This is a special case where we want to run all the terragrunt plans in one go to speed up initial deployment
# terragrunt run-all plan has however limitations as it will not be able to save the plan files for each modules at once
# as a consequence "PLAN Summary summary.txt" will be generated from outputs
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV
  terragruntPlan "RUNALL"
elif [[ $TRIGGER == "terragrunt-runall-apply" ]]
# This is a special case where we want to run all the terragrunt apply in one go to speed up initial deployment
# terragrunt run-all apply has however limitations as it will not be able to be triggered from previously saved plan file
# as a consequence it's meant to be used only for initial deployments
then
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV
  terragruntApply "RUNALL"
elif [[ $TRIGGER == "script-azurepolicies-scan" ]]
then
  export ARM_USE_MSI=true
  set -e
  workDir=`pwd`
  cd terraform/.modules/acf/modules/blueprint.policies.standard/scripts
  pwsh -command "./scan-policies.ps1 -global_vars $workDir/terragrunt/$CLIENT_ENV/global_vars.yaml -backend_subscription $SA_SUBSCRIPTION_ID -skipJobValidation true" 2>&1 | tee -a outfile
elif [[ $TRIGGER == "script-azurepolicies-remediation" ]]
then
  export ARM_USE_MSI=true
  set -e
  workDir=`pwd`
  cd terraform/.modules/acf/modules/blueprint.policies.standard/scripts
  ACF_ROOT_LEVEL=$(cat $workDir/terragrunt/$CLIENT_ENV/org.hcl | grep acf_root_level | sed 's/acf_root_level = //g' | sed 's/\"//g' | tr -d ' ' | tr -d '\r')
  pwsh -command "./remediate-policies.ps1 -RootManagementGroupIDs $ACF_ROOT_LEVEL -RemediateChildManagementGroups true" 2>&1 | tee -a outfile
elif [[ $TRIGGER == "script-vmmanagement-worker" ]]
then
  set -e
  workDir=`pwd`
  export ARM_USE_MSI=true
  cd terragrunt/$CLIENT_ENV/CORE/MANAGEMENT
  management_outputs=`terragrunt output -json management_outputs`
  management_group_id_scope=$(echo "$management_outputs" | jq -r '.vm_management_management_group_id_scope' | sed 's/^\[/(/' | sed 's/\]$/)/')
  exclude_subscriptions=$(echo "$management_outputs" | jq -r '.vm_management_exclude_subscriptions' | sed 's/^\[/(/' | sed 's/\]$/)/')
  cd $workDir/terraform/.modules/acf/modules/blueprint.management.standard/scripts
  if [ "$management_group_id_scope" != "null" ]; then
    pwsh -command "./register-provider.ps1 -management_group_id_scope $management_group_id_scope -exclude_subscriptions $exclude_subscriptions" 2>&1 | tee -a outfile
  fi
  echo "VM managemnet worker run success"
elif [[ $TRIGGER == "terragrunt-plugin-app-plan" ]]
then
  export ARM_USE_MSI=true
  cd "terragrunt/$CLIENT_ENV/APPLZ/$APP_NAME/PLUGINS/$PLUGIN_NAME"
  terragruntPlan "PLUGIN_APP"
elif [[ $TRIGGER == "terragrunt-plugin-app-apply" ]]
then
  export ARM_USE_MSI=true
  cd "terragrunt/$CLIENT_ENV/APPLZ/$APP_NAME/PLUGINS/$PLUGIN_NAME"
  terragruntApply "PLUGIN_APP"
elif [[ $TRIGGER == "terragrunt-plugin-management-plan" ]]
then
  export ARM_USE_MSI=true
  PLUGIN_NAME_MANAGEMENT=$PLUGIN_NAME"_MANAGEMENT"
  cd "terragrunt/$CLIENT_ENV/PLUGINS/$PLUGIN_NAME_MANAGEMENT/PLUGINS/$PLUGIN_NAME_MANAGEMENT"
  terragruntPlan "PLUGIN_MANAGEMENT"
elif [[ $TRIGGER == "terragrunt-plugin-management-apply" ]]
then
  export ARM_USE_MSI=true
  PLUGIN_NAME_MANAGEMENT=$PLUGIN_NAME"_MANAGEMENT"
  cd "terragrunt/$CLIENT_ENV/PLUGINS/$PLUGIN_NAME_MANAGEMENT/PLUGINS/$PLUGIN_NAME_MANAGEMENT"
  terragruntApply "PLUGIN_MANAGEMENT"
fiSandboxHost-638846409073741720:/bin$ ^C
SandboxHost-638846409073741720:/bin$ ^C
SandboxHost-638846409073741720:/bin$ command terminated with non-zero exit code: error executing command [/bin/bash], exit code 137
Connection closed. Press Enter to reconnect.
