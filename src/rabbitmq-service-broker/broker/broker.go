package broker

import (
	"context"
	"errors"
	"net/http"

	"rabbitmq-service-broker/config"

	"code.cloudfoundry.org/lager"
	rabbithole "github.com/michaelklishin/rabbit-hole"
	"github.com/pivotal-cf/brokerapi"
)

//go:generate counterfeiter -o ./fakes/api_client_fake.go $FILE APIClient

type APIClient interface {
	GetVhost(string) (*rabbithole.VhostInfo, error)
	PutVhost(string, rabbithole.VhostSettings) (*http.Response, error)
	UpdatePermissionsIn(vhost, username string, permissions rabbithole.Permissions) (res *http.Response, err error)
	PutPolicy(vhost, name string, policy rabbithole.Policy) (res *http.Response, err error)
	DeleteVhost(vhostname string) (res *http.Response, err error)
	PutUser(string, rabbithole.UserSettings) (*http.Response, error)
}

type RabbitMQServiceBroker struct {
	cfg    config.Config
	client APIClient
	logger lager.Logger
}

func New(cfg config.Config, client APIClient, logger lager.Logger) brokerapi.ServiceBroker {
	return &RabbitMQServiceBroker{
		cfg:    cfg,
		client: client,
		logger: logger,
	}
}

func (b RabbitMQServiceBroker) GetInstance(ctx context.Context, instanceID string) (brokerapi.GetInstanceDetailsSpec, error) {
	return brokerapi.GetInstanceDetailsSpec{}, errors.New("Not implemented")
}

func (b RabbitMQServiceBroker) Update(ctx context.Context, instanceID string, details brokerapi.UpdateDetails, asyncAllowed bool) (brokerapi.UpdateServiceSpec, error) {
	return brokerapi.UpdateServiceSpec{}, errors.New("Not implemented")
}

func (b RabbitMQServiceBroker) LastOperation(ctx context.Context, instanceID string, details brokerapi.PollDetails) (brokerapi.LastOperation, error) {
	return brokerapi.LastOperation{}, errors.New("Not implemented")
}

func (b RabbitMQServiceBroker) Unbind(ctx context.Context, instanceID, bindingID string, details brokerapi.UnbindDetails, asyncAllowed bool) (brokerapi.UnbindSpec, error) {
	return brokerapi.UnbindSpec{}, errors.New("Not implemented")
}

func (b RabbitMQServiceBroker) GetBinding(ctx context.Context, instanceID, bindingID string) (brokerapi.GetBindingSpec, error) {
	return brokerapi.GetBindingSpec{}, errors.New("Not implemented")
}

func (b RabbitMQServiceBroker) LastBindingOperation(ctx context.Context, instanceID, bindingID string, details brokerapi.PollDetails) (brokerapi.LastOperation, error) {
	return brokerapi.LastOperation{}, errors.New("Not implemented")
}
